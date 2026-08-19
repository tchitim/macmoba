// MacMoba — MobaXterm-style SSH client for macOS.
// SwiftUI app shell over MacMobaCore (SwiftNIO SSH + encrypted vault).

import AppKit
import MacMobaCore
import SwiftUI
import UserNotifications

/// Handles files and URLs opened from the Finder, the Dock, or a clicked link.
///
/// SwiftUI's `onOpenURL` only fires for URL schemes, not for double-clicked
/// documents, so this is the one place both a .rdp file and an ssh:// link
/// arriving from outside the app can be caught.
@MainActor
final class MacMobaAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the scene exists. Files opened before then wait here — the
    /// Finder can launch the app AND hand it a file before any window is up.
    static weak var app: AppState?
    static weak var window: WindowState?
    private static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.pending.append(contentsOf: urls)
        Self.drainPending()
    }

    static func drainPending() {
        guard let app, let window, !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        for url in urls {
            if url.pathExtension.lowercased() == "rdp" {
                RDPFileImport.open(url, into: app, window: window)
            } else {
                // ssh://, rdp://, vnc://… connect as a transient session.
                window.openURL(url)
            }
        }
    }
}

@main
struct MacMobaApp: App {
    @StateObject private var app = AppState()
    @StateObject private var updates = UpdateController()
    @NSApplicationDelegateAdaptor(MacMobaAppDelegate.self) private var delegate

    init() {
        // Needed when launched via `swift run` (no app bundle): give us a
        // real menu bar, dock icon and key-window focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // No native window tabs. MacMoba already has its own tab bar for
        // sessions, so the system one stacks a second, unrelated row of tabs on
        // top of it — and clicking its "+" crashed 1.56: AppKit asks SwiftUI to
        // build a window for the new tab, SwiftUI replays the saved toolbar
        // configuration into it, and NSToolbar throws while inserting the items
        // (see the 1.56 crash report: _makeNewWindowInTab →
        // _insertNewItemWithItemIdentifier:…propertyListRepresentation:).
        // ⌘N still opens a real window, which is what the per-window session
        // model expects anyway.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        // A WindowGroup gives ⌘N for free; each window gets its own
        // WindowState (its own tabs) over the one shared AppState.
        WindowGroup("MacMoba") {
            RootView(app: app)
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            MacMobaCommands(app: app)
            // Sits in the app menu, next to About — where every Mac app keeps it.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(controller: updates)
            }
        }

        // The management home for macros / credentials / templates (P1-4):
        // one window, opened on demand, instead of three permanent sidebar
        // sections. Appears in the Window menu automatically.
        Window("Library", id: "library") {
            LibraryView()
                .environmentObject(app)
        }
        // ⌥⌘L, not ⇧⌘L — that is Session Log's established shortcut.
        .keyboardShortcut("l", modifiers: [.command, .option])

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}

/// Menu commands. Anything acting on tabs goes through `@FocusedObject`, so it
/// lands on the window you are actually looking at rather than a remembered one.
struct MacMobaCommands: Commands {
    @ObservedObject var app: AppState
    @FocusedObject private var window: WindowState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // File: how things are opened and moved in and out. Session actions,
        // pane layout and tools each have their own menu (P1-6) — this menu
        // had grown to seventeen items across four mental categories.
        CommandGroup(after: .newItem) {
            Button("New Local Terminal") { window?.openLocalTerminal() }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(window == nil)
            Button("Quick Connect…") { window?.showQuickConnect = true }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(window == nil)
            Button("Open RDP File…") { RDPFileImport.chooseAndOpen(into: app, window: window) }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(window == nil)
            Divider()
            Button("Import ~/.ssh/config…") { app.confirmImportSSHConfig() }
            Button("Import Sessions…") { SessionTransfer.importSessions(into: app) }
            Button("Export Sessions…") { SessionTransfer.export(from: app) }
        }
        // Session: acting on the connection you are looking at.
        CommandMenu("Session") {
            Button("Connect Selected Session") {
                if let w = window, let id = w.selectedSessionID,
                   let s = app.data.sessions.first(where: { $0.id == id }) {
                    w.openTab(for: s)
                }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(window?.selectedSessionID == nil)
            Button("Disconnect Tab") { window?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(window?.selectedTab == nil)
            Toggle("Broadcast Input (MultiExec)", isOn: $app.broadcastInput)
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            // Capturing input takes this Mac's own shortcuts away, so the way
            // out is documented where the behaviour is turned on.
            // Hand-made binding: the bridge is its own observable object, so
            // there is no $app projection reaching into it.
            Toggle("Capture Input on Click (Esc Esc to release)",
                   isOn: Binding(get: { app.vncKeyboard.capturesOnClick },
                                 set: { app.vncKeyboard.capturesOnClick = $0 }))
            Button("Release Captured Input") { app.vncKeyboard.release() }
                .disabled(!app.vncKeyboard.isGrabbed)
            Button("Paste to Remote Desktop") {
                if !app.vncKeyboard.typeClipboardIntoFocusedDesktop() {
                    app.lastError = "No remote desktop in this window."
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Copy VNC Diagnostics") {
                app.copyVNCDiagnostics()
                app.infoMessage = "VNC diagnostics copied."
            }
            Divider()
            Button(window?.selectedTab?.focusedPane?.logURL == nil
                   ? "Start Session Log" : "Stop Session Log") {
                window?.toggleSessionLog()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            // Logging records a pane's output, so it needs a pane tree. On a
            // VNC/RDP tab `focusedPane` is the unused placeholder leaf, so this
            // used to start logging a terminal that is not connected to
            // anything — an empty log file, and a menu item stuck on "Stop".
            .disabled(window?.selectedTab?.isSinglePane ?? true)
            Button("Open Logs Folder") {
                NSWorkspace.shared.open(SessionLogger.directory)
            }
            Button("Send File (ZMODEM)…") { window?.sendFileViaZModem() }
                .disabled(window?.selectedTab?.isSinglePane ?? true)
            Divider()
            Button("Jump to Attention") { window?.jumpToAttention() }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(window == nil)
        }
        CommandGroup(after: .textEditing) {
            // Routed through the responder chain so it lands on whichever
            // terminal has focus, like the standard Copy/Paste items.
            Button("Paste as One Line") {
                NSApp.sendAction(Selector(("pasteAsOneLine:")), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            // Search runs over a terminal's scrollback, which a VNC/RDP tab does
            // not have. `toggleSearch` already refuses those; this stops the
            // menu from claiming otherwise.
            Button("Find…") { window?.toggleSearch() }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(window?.selectedTab?.isSinglePane ?? true)
            Button("Find Next") { window?.findNext() }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(window?.selectedTab?.isSinglePane ?? true)
            Button("Find Previous") { window?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(window?.selectedTab?.isSinglePane ?? true)
        }
        // ⌃⌘n rather than ⌘n or ⌃n: plain ⌃-digit is a control character
        // the terminal should keep receiving, and ⌘-digit is what people
        // expect to switch tabs.
        CommandMenu("Macros") {
            if app.data.macros.isEmpty {
                Text("No macros yet — add one in the Library (⌥⌘L)")
            } else {
                ForEach(Array(app.data.macros.prefix(9).enumerated()),
                        id: \.element.id) { index, macro in
                    Button(macro.name) { window?.runMacro(macro) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                          modifiers: [.control, .command])
                }
                if app.data.macros.count > 9 {
                    Divider()
                    ForEach(app.data.macros.dropFirst(9)) { macro in
                        Button(macro.name) { window?.runMacro(macro) }
                    }
                }
            }
        }
        // Tools: utilities that stand apart from any one session.
        CommandMenu("Tools") {
            Button("Generate SSH Key…") { window?.showKeyGen = true }
                .disabled(window == nil)
            Button("Network Tools…") { window?.showNetworkTools = true }
                .disabled(window == nil)
            Button("Trusted Hosts…") { window?.showTrustedHosts = true }
                .disabled(window == nil)
            Divider()
            Button("Library") { openWindow(id: "library") }
        }
        CommandGroup(after: .sidebar) {
            Divider()
            // Splitting only applies to terminal tabs: VNC, RDP and local-shell
            // tabs own their whole tab rather than a pane tree. Greyed out
            // rather than silently doing nothing.
            Button("Split Right") { window?.smartSplit(.horizontal) }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(window?.selectedTab?.isSinglePane ?? true)
            Button("Split Down") { window?.smartSplit(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(window?.selectedTab?.isSinglePane ?? true)
            Button("Tile Panes") {
                window?.selectedTab?.tileIntoGrid()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled((window?.selectedTab?.panes.count ?? 0) < 2
                      || (window?.selectedTab?.isSinglePane ?? true))
            Button("Move Panes to Separate Tabs") {
                if let tab = window?.selectedTab { window?.ungroupPanes(of: tab) }
            }
            .disabled((window?.selectedTab?.panes.count ?? 0) < 2
                      || (window?.selectedTab?.isSinglePane ?? true))
            Button("Close Pane") { window?.closeFocusedPane() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(window?.selectedTab == nil)
            Divider()
            Button("Overview") { window?.showOverview = true }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(window == nil)
            // Also in the toolbar, but a toolbar icon can overflow into the
            // chevron on a narrow window — and an icon is not something you
            // can look up. The menu is where a feature is findable.
            Toggle("Health Monitoring", isOn: Binding(
                get: { app.healthMonitor.isEnabled },
                set: { app.healthMonitor.isEnabled = $0 }))
            Button(window?.showInspector == true ? "Hide Inspector" : "Show Inspector") {
                window?.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(window == nil)
            // Deliberately not ⌃⌘F: that is the system's own Enter Full Screen,
            // which leaves our sidebar and tab bar in place. This is the one
            // that gives the remote machine the whole screen.
            Button(window?.focusRemoteDesktop == true
                   ? "Exit Full Screen Session" : "Full Screen Session") {
                window?.toggleRemoteDesktopFocus()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift, .control])
            .disabled(!(window?.canFocusRemoteDesktop ?? false)
                      && window?.focusRemoteDesktop != true)
            Divider()
            Picker("Terminal Theme", selection: $app.themeID) {
                Text("Auto (match system)").tag(TerminalTheme.autoID)
                Divider()
                ForEach(TerminalTheme.all) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            Divider()
            Button("Increase Font Size") { app.adjustFontSize(1) }
                .keyboardShortcut("+", modifiers: [.command])
            Button("Decrease Font Size") { app.adjustFontSize(-1) }
                .keyboardShortcut("-", modifiers: [.command])
            Button("Reset Font Size") { app.resetFontSize() }
                .keyboardShortcut("0", modifiers: [.command])
            Divider()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    /// One per window. The autoclosure runs once per view lifetime, so each
    /// window keeps its own tabs across redraws.
    @StateObject private var window: WindowState

    init(app: AppState) {
        _window = StateObject(wrappedValue: WindowState(app: app))
    }

    /// Restore runs once, on the primary window, the first time the vault opens.
    @State private var didRestore = false

    var body: some View {
        Group {
            if app.unlocked {
                ContentView()
            } else {
                VaultGateView()
            }
        }
        .environmentObject(window)
        // Lets the menu bar find this window's state when it is key.
        .focusedSceneObject(window)
        .background(WindowAccessor { window.watchForClose(of: $0) })
        .onChange(of: app.unlocked) { unlocked in
            // Reopen last session's tabs — but only in the first window, and only
            // once per launch, so a re-unlock (lock then unlock) does not pile on
            // duplicate tabs.
            if unlocked, !didRestore, app.windows.first === window {
                didRestore = true
                window.restoreWorkspace()
            }
        }
        .onAppear {
            // A .rdp double-clicked in the Finder can reach the delegate
            // before any window exists; this is where those get handled.
            MacMobaAppDelegate.app = app
            MacMobaAppDelegate.window = window
            MacMobaAppDelegate.drainPending()
            // Clicking an attention notification lands on its pane.
            if Bundle.main.bundleIdentifier != nil {
                UNUserNotificationCenter.current().delegate = AttentionNotificationDelegate.shared
            }
            AttentionNotifier.openPane = { [weak app] paneID in
                guard let app else { return }
                if let tab = app.allTabs.first(where: { t in
                    t.panes.contains { $0.id == paneID }
                }) {
                    app.focus(tab: tab)
                    tab.focusedPaneID = tab.panes.first { $0.id == paneID }?.id
                        ?? tab.focusedPaneID
                    tab.panes.first { $0.id == paneID }?.clearAttention()
                } else if let tab = app.allTabs.first(where: { $0.id == paneID }) {
                    // Tab-level notifications (agent-event) address the tab id.
                    app.focus(tab: tab)
                    tab.localTerminal?.clearAttention()
                }
            }
        }
        // Results and errors surface as a banner rather than an OK-only modal
        // (P0-3); the queue lives in AppState so any call site can notify.
        .overlay(alignment: .top) {
            AppBannerView().environmentObject(app)
        }
        .sheet(isPresented: $window.showQuickConnect) {
            QuickConnectView { window.quickConnect($0) }
        }
        .sheet(isPresented: $window.showTrustedHosts) {
            TrustedHostsView(ssh: app.knownHosts, rdp: RDPCertificateStore.shared)
        }
        .sheet(isPresented: $window.showOverview) {
            OverviewView().environmentObject(app).environmentObject(window)
        }
        .sheet(isPresented: $window.showKeyGen) {
            KeyGenView()
        }
        .sheet(isPresented: $window.showNetworkTools) {
            NetworkToolsView()
        }
    }
}

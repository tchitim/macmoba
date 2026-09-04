// Per-window state: the tabs this window shows and everything that acts on them.
//
// AppState is the shared document — one vault, one session list, one set of
// running tunnels, no matter how many windows are open. Anything that is "what
// am I looking at right now" belongs here instead, so a second window can hold
// a different set of connections.

import Foundation
import MacMobaCore
import SwiftUI

@MainActor
final class WindowState: ObservableObject {
    @Published var tabs: [SessionTab] = []
    @Published var selectedTabID: UUID? {
        didSet {
            // The tab being left is still on screen at this point — a moment
            // later SwiftUI takes its view out of the window and it can no
            // longer be photographed. This is the only chance to keep a
            // thumbnail for the Overview.
            if oldValue != selectedTabID {
                tabs.first { $0.id == oldValue }?.cacheSnapshot()
            }
            // Viewing a local tab satisfies its agent-hook attention.
            tabs.first { $0.id == selectedTabID }?.localTerminal?.clearAttention()
        }
    }
    /// Sidebar selection highlight.
    @Published var selectedSessionID: String?
    /// The sidebar group whose dashboard the inspector shows (P2-13). Mutually
    /// exclusive with a selected session.
    @Published var selectedGroup: String?
    @Published var showQuickConnect = false
    @Published var showTrustedHosts = false
    @Published var showOverview = false
    @Published var showDiscover = false
    @Published var showKeyGen = false
    @Published var showNetworkTools = false
    /// The trailing inspector panel (P1-5); remembered across launches.
    @Published var showInspector: Bool = UserDefaults.standard.bool(forKey: "showInspector") {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }

    /// The document. Unowned because AppState outlives every window: it is the
    /// app's own @StateObject.
    unowned let app: AppState

    init(app: AppState) {
        self.app = app
        app.register(self)
    }

    private var closeObserver: NSObjectProtocol?
    private var fullScreenObserver: NSObjectProtocol?
    private var enterFullScreenObserver: NSObjectProtocol?
    private weak var nsWindow: NSWindow?

    /// Give the remote desktop the whole window: sidebar and tab bar hidden,
    /// window in full screen. Only meaningful for VNC/RDP tabs, where the point
    /// is to see the remote machine rather than our chrome.
    @Published private(set) var focusRemoteDesktop = false

    /// True when the selected tab is something worth going full screen for.
    var canFocusRemoteDesktop: Bool {
        guard let tab = selectedTab else { return false }
        return tab.isVNC || tab.isRDP
    }

    func toggleRemoteDesktopFocus() {
        // Leaving is always allowed — otherwise switching to a terminal tab
        // while focused would strand the window with no way back.
        guard focusRemoteDesktop || canFocusRemoteDesktop else { return }
        setRemoteDesktopFocus(!focusRemoteDesktop)
    }

    private func setRemoteDesktopFocus(_ on: Bool) {
        guard focusRemoteDesktop != on else { return }
        focusRemoteDesktop = on
        // Closing the extra windows can happen immediately, but OPENING them
        // must wait until the full-screen transition has finished: macOS moves
        // this window to a Space of its own on the way in, and windows created
        // before that lands end up behind it or on the wrong Space — which
        // shows up as a screen that stays black.
        // The open happens in the didEnterFullScreen observer below.
        if !on { selectedTab?.rdp?.setSpanning(false) }
        // Chrome and full screen are toggled together, but the window may
        // already be full screen for its own reasons — do not fight the user.
        let isFullScreen = nsWindow?.styleMask.contains(.fullScreen) ?? false
        if on != isFullScreen { nsWindow?.toggleFullScreen(nil) }
    }

    /// Closing a window must close its connections. Nothing else retains them —
    /// SSHConnection's callbacks hold the pane weakly — so without this the
    /// channel stays open with no way left to reach it.
    ///
    /// Driven by the real `NSWindow` close rather than `deinit` (which cannot
    /// touch main-actor state) or `onDisappear` (which fires for view lifecycle
    /// reasons that are not a window closing, and would drop live sessions).
    func watchForClose(of nsWindow: NSWindow?) {
        guard let nsWindow, closeObserver == nil else { return }
        self.nsWindow = nsWindow
        // Full screen can also be left by the green button, Esc, or a Spaces
        // gesture. Without following that, the sidebar and tab bar would stay
        // hidden with no visible way to bring them back.
        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nsWindow, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.focusRemoteDesktop = false
                self.selectedTab?.rdp?.setSpanning(false)
            }
        }
        enterFullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: nsWindow, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.focusRemoteDesktop else { return }
                self.selectedTab?.rdp?.setSpanning(true)
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nsWindow, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let token = self.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.closeObserver = nil
                }
                for token in [self.fullScreenObserver, self.enterFullScreenObserver] {
                    if let token { NotificationCenter.default.removeObserver(token) }
                }
                self.fullScreenObserver = nil
                self.enterFullScreenObserver = nil
                self.closeAllTabs()
            }
        }
    }

    var selectedTab: SessionTab? { tabs.first { $0.id == selectedTabID } }

    // MARK: - Tabs

    func openTab(for storedConfig: SessionConfig) {
        // Fill in the login from a shared credential (if any) before connecting.
        // Resolution keeps the same id, host and kind — only the login changes —
        // so everything downstream, including ProxyJump matching, still works.
        let config = app.resolved(storedConfig)
        let tab: SessionTab
        switch config.sessionKind {
        // Telnet and Serial are terminals, so they get the full pane tab; a
        // serial pane just cannot be split (see fitsInSplitPane).
        case .ssh, .telnet, .mosh, .rlogin, .serial:
            tab = SessionTab(config: config, app: app)
        // A file browser and nothing else: no shell to give it a pane tree.
        case .ftp:
            tab = SessionTab(files: config, app: app)
        case .web:
            tab = SessionTab(web: config, app: app)
        case .vnc:
            tab = SessionTab(vnc: config, app: app)
        case .rdp:
            tab = SessionTab(rdp: config, app: app)
        }
        tabs.append(tab)
        selectedTabID = tab.id
        app.saveOpenWorkspace()
    }

    /// Reopen the sessions that were open last time. Called once, on the primary
    /// window, after the vault unlocks.
    func restoreWorkspace() {
        let sessions = Dictionary(app.data.sessions.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        for layout in app.restorableWorkspace().tabs {
            if case .leaf(let id) = layout {
                // One pane: the ordinary path, so a plain tab restores exactly
                // as it always did.
                if let session = sessions[id] { openTab(for: session) }
            } else if let tab = SessionTab.restore(layout, sessions: sessions, app: app) {
                tabs.append(tab)
                selectedTabID = tab.id
            }
        }
    }

    /// MobaXterm-style local shell tab.
    func openLocalTerminal() {
        let tab = SessionTab(localShellIn: nil, app: app)
        tabs.append(tab)
        selectedTabID = tab.id
    }



    /// Open a tab for every session in the group (pairs well with MultiExec).
    /// Cycle to the next tab whose pane wants the user (cmux jump-to-unread).
    func jumpToAttention() {
        guard tabs.contains(where: { $0.attentionCount > 0 }) else { return }
        let start = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        // Rotate so the search begins just after the current tab and wraps.
        let order = Array(tabs[(start + 1)...]) + Array(tabs[...start])
        guard let next = order.first(where: { $0.attentionCount > 0 }) else { return }
        selectedTabID = next.id
        if let pane = next.panes.first(where: { $0.needsAttention }) {
            next.focusedPaneID = pane.id
            pane.clearAttention()
        }
    }

    func connectGroup(_ group: String) {
        // A folder is its subtree: Connect All on "Production" opens Linux and
        // Windows subfolders' sessions too.
        for session in app.data.sessions
        where GroupTree.contains(group, group: session.group) {
            openTab(for: session)
        }
    }

    /// Quick Connect: "user@host:port" (or "host"), connect without saving.
    func quickConnect(_ text: String) {
        guard let config = QuickConnectParser.parse(text) else { return }
        openTab(for: config)
    }

    /// Open a connection URL (ssh://user@host:port, rdp://…, etc.) as a
    /// transient session — the same "connect without saving" path as Quick
    /// Connect. Returns false if the URL is not one of our schemes.
    @discardableResult
    func openURL(_ url: URL) -> Bool {
        guard let config = SessionURL.parse(url) else { return false }
        openTab(for: config)
        return true
    }

    /// Reorder the tab bar. Purely a change of order — the tabs keep their
    /// connections, their panes and their scrollback, because nothing here
    /// touches anything but the array.
    func moveTab(id: UUID, before targetID: UUID) {
        let order = ListReorder.move(id, toward: targetID, in: tabs.map(\.id))
        guard order != tabs.map(\.id) else { return }
        // Rebuild from the existing objects: the tabs themselves are untouched,
        // so connections, panes and scrollback all survive the reorder.
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        tabs = order.compactMap { byID[$0] }
    }

    func closeTab(_ tab: SessionTab) {
        tab.disconnectAll()
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
        app.saveOpenWorkspace()
    }

    /// Select `tab` and bring this window to the front, if it lives here.
    @discardableResult
    func focus(_ tab: SessionTab) -> Bool {
        guard tabs.contains(where: { $0.id == tab.id }) else { return false }
        selectedTabID = tab.id
        nsWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    func closeSelectedTab() {
        if let tab = selectedTab { closeTab(tab) }
    }

    /// Disconnect everything this window holds — used when the vault locks and
    /// when the window itself goes away.
    func closeAllTabs() {
        for tab in tabs { tab.disconnectAll() }
        tabs.removeAll()
        selectedTabID = nil
    }

    // MARK: - Split panes

    /// Duplicate the focused pane's session into a new pane.
    func splitSelected(_ axis: Axis) {
        selectedTab?.splitFocused(axis)
    }

    /// Keyboard split (⌘D/⇧⌘D): pull the next open tab into the split when
    /// there is one; only duplicate when this is the sole tab.
    func smartSplit(_ axis: Axis) {
        guard let tab = selectedTab, tab.canSplit else { return }
        // Only terminal tabs can be moved in; a VNC/RDP tab next door is not a
        // candidate, so fall back to duplicating this pane rather than merging
        // something that cannot be a pane.
        if let other = tabs.first(where: { $0.id != tab.id && $0.hasTerminalPanes }) {
            mergeTab(other, into: tab, axis: axis)
        } else {
            tab.splitFocused(axis)
        }
    }

    /// Open a different saved session in a new pane of the current tab.
    /// Put any saved session beside the focused pane — a remote desktop next to
    /// a shell is the point of this, not an edge case.
    func splitWithLocalShell(_ axis: Axis) {
        selectedTab?.splitFocusedWithLocalShell(axis)
        app.saveOpenWorkspace()
    }


    func splitWithNewConnection(_ config: SessionConfig, axis: Axis) {
        _ = selectedTab?.splitFocused(axis, with: app.resolved(config))
        app.saveOpenWorkspace()
    }

    /// MobaXterm-style split: move an existing open tab into the current tab
    /// as a new pane. The moved terminals stay connected. Both tabs must belong
    /// to this window — a terminal view cannot live in two windows at once.
    /// Bring every terminal tab in this window together and lay them out as a
    /// grid — what MultiExec is for: seeing the machines you are typing into.
    ///
    /// VNC, RDP and local-shell tabs are left alone; they cannot be panes.
    /// Returns the tab everything ended up in.
    /// Panes that `gatherTerminalsIntoGrid` pulled out of their own tabs, so
    /// switching MultiExec off can put them back exactly as they were and not
    /// disturb any pane the user split by hand.
    private var gatheredPaneIDs: Set<UUID> = []

    /// Undo the gather: every pane that was pulled in gets its tab back.
    ///
    /// Also available on its own (File ▸ Move Panes to Separate Tabs), because
    /// a layout you cannot get out of is a trap.
    func scatterGatheredPanes() {
        guard !gatheredPaneIDs.isEmpty else { return }
        let ids = gatheredPaneIDs
        gatheredPaneIDs = []
        for tab in tabs where tab.hasTerminalPanes {
            for pane in tab.panes where ids.contains(pane.id) {
                movePaneToOwnTab(.terminal(pane), from: tab)
            }
        }
    }

    /// Split every pane of `tab` out into its own tab, keeping one behind.
    /// Break a split apart: every pane becomes its own tab, connections intact.
    /// Every pane, not every terminal — a remote desktop sharing the split is
    /// one of the things you are trying to separate.
    func ungroupPanes(of tab: SessionTab) {
        for content in SessionTab.contents(tab.root).dropFirst() {
            movePaneToOwnTab(content, from: tab)
        }
        gatheredPaneIDs = []
        app.saveOpenWorkspace()
    }

    @discardableResult
    private func movePaneToOwnTab(_ content: SessionTab.PaneContent,
                                  from tab: SessionTab) -> SessionTab? {
        let config = tab.config(of: content)
        guard tab.detach(content) else { return nil }
        let newTab = SessionTab(adopting: content, config: config, app: app)
        tabs.append(newTab)
        return newTab
    }

    @discardableResult
    func gatherTerminalsIntoGrid() -> SessionTab? {
        let terminals = tabs.filter(\.hasTerminalPanes)
        guard terminals.count > 1 || (terminals.first?.panes.count ?? 0) > 1 else {
            terminals.first?.tileIntoGrid()
            return terminals.first
        }
        // The selected tab if it is a terminal, so the view does not jump.
        let destination = (selectedTab.flatMap { $0.hasTerminalPanes ? $0 : nil })
            ?? terminals[0]
        for source in terminals where source.id != destination.id {
            // Remembered so switching MultiExec off can hand them back. Only
            // panes that are not already here — re-merging a tab that was
            // never scattered would otherwise record the same pane twice.
            let incoming = source.panes.map(\.id)
            gatheredPaneIDs.formUnion(incoming)
            mergeTab(source, into: destination, axis: .horizontal)
        }
        selectedTabID = destination.id
        destination.tileIntoGrid()
        return destination
    }

    func mergeTab(_ source: SessionTab, into dest: SessionTab, axis: Axis) {
        guard source.id != dest.id,
              tabs.contains(where: { $0.id == source.id }),
              tabs.contains(where: { $0.id == dest.id }) else { return }
        // Both sides must own a pane tree. A local shell or a bare file browser
        // keeps its content outside one, so there is nothing to hand over —
        // everything else, remote desktops included, is now leaves.
        guard source.canSplit, dest.canSplit else { return }
        let node = source.root
        source.prepareForMerge()
        tabs.removeAll { $0.id == source.id }
        dest.merge(node: node, axis: axis)
        selectedTabID = dest.id
        app.saveOpenWorkspace()
    }

    func closeFocusedPane() {
        guard let tab = selectedTab, let pane = tab.focusedPane else { return }
        if !tab.closePane(pane) {
            closeTab(tab)
        }
    }

    /// Close a non-terminal leaf; the tab goes when its last leaf does.
    func closePaneContent(_ content: SessionTab.PaneContent, in tab: SessionTab) {
        if !tab.closeContent(content) {
            closeTab(tab)
        }
        app.saveOpenWorkspace()
    }

    func closePane(_ pane: TerminalTab, in tab: SessionTab) {
        if !tab.closePane(pane) {
            closeTab(tab)
        }
        app.saveOpenWorkspace()
    }

    // MARK: - Search / logging

    func toggleSearch() {
        guard let tab = selectedTab, tab.canSplit else { return }
        tab.showSearch.toggle()
        if tab.showSearch {
            tab.search.attach(to: tab.focusedPane)
        }
    }

    func findNext() { paneSearch?.next() }
    func findPrevious() { paneSearch?.previous() }

    /// Search only exists for tabs that have a terminal pane tree.
    private var paneSearch: TerminalSearchModel? {
        guard let tab = selectedTab, tab.hasTerminalPanes else { return nil }
        return tab.search
    }

    /// Start/stop writing the focused pane's output to a log file.
    /// No alert: a modal would steal focus from the terminal you just started
    /// logging, and the path is already printed into the session itself.
    func toggleSessionLog() {
        // Not merely a disabled menu item: on a VNC/RDP tab `focusedPane` is the
        // placeholder leaf, so this would open a log file for a terminal that
        // never receives a byte.
        guard let tab = selectedTab, tab.hasTerminalPanes else { return }
        tab.focusedPane?.toggleLogging()
    }

    /// Prompt for a file and push it to the remote over ZMODEM (runs `rz` there).
    func sendFileViaZModem() {
        guard let pane = selectedTab?.focusedPane else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pane.sendFileViaZModem(url)
    }

    // MARK: - Macros

    /// Type a macro into this window's focused terminal. Goes through the
    /// terminal view's send path rather than straight to the connection, so a
    /// macro obeys MultiExec broadcast exactly like typing it by hand would.
    func runMacro(_ macro: MacroConfig) {
        guard let tab = selectedTab else {
            app.lastError = "Open a terminal tab first — a macro types into the focused terminal."
            return
        }
        let keystrokes = macro.keystrokes
        guard !keystrokes.isEmpty else { return }
        if let local = tab.localTerminal {
            local.engine.engineSendText(keystrokes)
            return
        }
        guard let pane = tab.focusedPane, pane.state == .connected else {
            app.lastError = "“\(macro.name)” needs a connected terminal."
            return
        }
        // One keystroke reaching a whole fleet deserves a look at the list
        // first. Only worth asking when broadcast actually widens the blast
        // radius — with a single session it changes nothing. Targets span every
        // window, because that is where broadcast sends.
        let targets = app.broadcastTargets
        if app.broadcastInput, app.confirmBroadcastMacros, targets.count > 1 {
            MacroBroadcastPrompt.confirm(
                macro: macro,
                targets: targets,
                window: pane.engine.engineView.window,
                onSuppress: { [weak app] in app?.confirmBroadcastMacros = false }
            ) { [weak pane] confirmed in
                guard confirmed, let pane else { return }
                pane.engine.engineSendText(keystrokes)
            }
            return
        }
        pane.engine.engineSendText(keystrokes)
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view. SwiftUI offers no direct
/// handle, and window teardown has to key off the real AppKit window.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view is not in a window yet during make; resolve on the next turn.
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Parsing "user@host:port" is pure, so it lives apart from the window that
/// happens to be asking.
enum QuickConnectParser {
    static func parse(_ text: String) -> SessionConfig? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var user = NSUserName()
        var hostPart = trimmed
        if let at = trimmed.lastIndex(of: "@") {
            user = String(trimmed[trimmed.startIndex..<at])
            hostPart = String(trimmed[trimmed.index(after: at)...])
        }
        var port = 22
        if let colon = hostPart.lastIndex(of: ":"),
           let parsed = Int(hostPart[hostPart.index(after: colon)...]) {
            port = parsed
            hostPart = String(hostPart[hostPart.startIndex..<colon])
        }
        guard !hostPart.isEmpty else { return nil }
        return SessionConfig(name: "\(user)@\(hostPart)", host: hostPart,
                             port: port, username: user)
    }
}

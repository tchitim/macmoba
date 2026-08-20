// Main window: sidebar (sessions / tunnels) + terminal tab area.

import MacMobaCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState

    /// Driven by `window.focusRemoteDesktop` rather than read from it directly,
    /// because NavigationSplitView needs a binding it can also write to when the
    /// user drags the sidebar closed themselves.
    @State private var columns: NavigationSplitViewVisibility = .all
    private var health: HealthMonitor { app.healthMonitor }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                // The max matters. Once a terminal is showing, the split view
                // will not leave the sidebar more than about a third of the
                // window (300 of our 900pt minimum). Any wider — dragged, or
                // restored from a previous run — and it gets squeezed on the
                // next layout without its List re-laying out, so every row
                // renders shifted off the left edge and the sidebar looks
                // blank. Capping at the width it would be squeezed to means
                // the squeeze never happens.
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 300)
        } detail: {
            HStack(spacing: 0) {
                TerminalArea()
                if window.showInspector {
                    Divider()
                    // Hand-rolled trailing panel: `.inspector` needs macOS 14
                    // and this app supports 13. Same 260-pt column either way.
                    SessionInspectorView()
                }
            }
        }
        .environmentObject(health)
        .onAppear { health.sessionsProvider = { [weak app] in app?.data.sessions ?? [] } }
        // A plain toolbar, deliberately: the customizable form (.toolbar(id:))
        // crashed 1.56 when AppKit built a window for a native tab — SwiftUI
        // replays the saved configuration and NSToolbar throws inserting the
        // items. Native window tabbing is off now too, but this keeps the
        // fragile propertyList path out of the app entirely.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: Binding(get: { health.isEnabled },
                                     set: { on in
                    health.isEnabled = on
                    // Turning it on changes little on screen until the first
                    // sweep lands — and nothing at all if the folders are shut.
                    // Say so, rather than leaving the button looking inert.
                    let checkable = app.data.sessions.filter(\.isDirectlyProbeable).count
                    app.infoMessage = on
                        ? (checkable > 0
                           ? "Health monitoring on — checking \(checkable) host(s) every 15s."
                           : "Health monitoring on — no directly reachable hosts to check.")
                        : "Health monitoring off."
                })) {
                    Label("Health", systemImage: health.isEnabled
                          ? "heart.text.square.fill" : "heart.text.square")
                }
                .toggleStyle(.button)
                // Tinted, not just recessed: with labels showing, the pressed
                // look alone was not read as "on".
                .foregroundStyle(health.isEnabled ? Color.green : Color.primary)
                .help("Poll saved hosts and show reachability lights in the sidebar")
            }
            ToolbarItem(placement: .automatic) {
                SplitMenu(axis: .horizontal, title: "Split Right", icon: "rectangle.split.2x1")
            }
            ToolbarItem(placement: .automatic) {
                SplitMenu(axis: .vertical, title: "Split Down", icon: "rectangle.split.1x2")
            }
            ToolbarItem(placement: .automatic) {
                Button { window.showOverview = true } label: {
                    Label("Overview", systemImage: "square.grid.2x2")
                }
                .help("Overview of all open connections (⇧⌘0)")
            }
            ToolbarItem(placement: .automatic) {
                FilesToggle()
            }
            ToolbarItem(placement: .automatic) {
                TransferToggle()
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: Binding(
                    get: { app.broadcastInput },
                    set: { on in
                        app.broadcastInput = on
                        // Switching it on brings the terminal tabs together and
                        // lays them out as a grid: broadcasting to sessions you
                        // cannot see is the thing this is meant to avoid.
                        // Switching it off hands them back — a layout you
                        // cannot get out of is a trap.
                        if on {
                            window.gatherTerminalsIntoGrid()
                        } else {
                            window.scatterGatheredPanes()
                        }
                    })) {
                    Label("MultiExec", systemImage: app.broadcastInput && app.broadcastIsPartial
                          ? "antenna.radiowaves.left.and.right.slash"
                          : "dot.radiowaves.left.and.right")
                }
                .toggleStyle(.button)
                .help(app.broadcastIsPartial
                      ? "Broadcast keyboard input to the chosen panes"
                      : "Broadcast keyboard input to all connected panes")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    app.lockVault()
                } label: {
                    Label("Lock", systemImage: "lock")
                }
                .help("Lock the vault and disconnect everything")
            }
        }
        .onChange(of: window.focusRemoteDesktop) { focused in
            columns = focused ? .detailOnly : .all
        }
    }
}

/// Split menu: primary action is pulling an existing open tab into the split
/// (MobaXterm-style); new connections and duplication are also offered.
struct SplitMenu: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState
    let axis: Axis
    let title: String
    let icon: String

    var body: some View {
        Menu {
            if let current = window.selectedTab, current.canSplit {
                // Any tab with a tree can be moved in, desktops included: the
                // connection travels with the leaf rather than belonging to the
                // tab it started in.
                let others = window.tabs.filter { $0.id != current.id && $0.canSplit }
                if !others.isEmpty {
                    Section("Move Open Tab Here") {
                        ForEach(others) { other in
                            Button(other.title) {
                                window.mergeTab(other, into: current, axis: axis)
                            }
                        }
                    }
                }
                if current.paneCount > 1 {
                    Section {
                        // Where someone looks for "undo the split" is the same
                        // menu that made it, not a different one.
                        Button("Break Apart into Tabs") {
                            window.ungroupPanes(of: current)
                        }
                    }
                }
                Section("New Connection") {
                    Button("Duplicate Current Session") {
                        window.splitSelected(axis)
                    }
                    // Every kind, not just terminals: a remote desktop beside a
                    // shell is exactly what people ask splits for. Serial is the
                    // one exception — one port, one connection.
                    ForEach(app.data.sessions.filter { $0.sessionKind != .serial }) { session in
                        Button(session.name) {
                            window.splitWithNewConnection(session, axis: axis)
                        }
                    }
                }
            }
        } label: {
            Label(title, systemImage: icon)
        }
        .help("\(title): move an open tab here, or open a new connection")
        .disabled(window.selectedTab == nil)
    }
}

/// Toolbar toggle for the two-pane transfer view: this Mac on the left, the
/// session's server on the right. Disabled for tabs with no file service —
/// a local shell, VNC or RDP.
struct TransferToggle: View {
    @EnvironmentObject var window: WindowState

    var body: some View {
        if let tab = window.selectedTab, tab.supportsTransfer {
            TransferToggleInner(tab: tab)
        } else {
            Button {} label: {
                Label("Transfer", systemImage: "arrow.left.arrow.right.square")
            }
            .disabled(true)
        }
    }
}

struct TransferToggleInner: View {
    @ObservedObject var tab: SessionTab

    var body: some View {
        Toggle(isOn: Binding(
            get: { tab.showTransfer },
            set: { on in
                // Built here rather than in the view's body: creating the panes
                // during a view update is a state mutation SwiftUI may loop on.
                if on { tab.prepareTransfer() }
                tab.showTransfer = on
            })) {
            Label("Transfer", systemImage: "arrow.left.arrow.right.square")
        }
        .toggleStyle(.button)
        .help("Two-pane file transfer: this Mac on the left, the server on the right")
        .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}

/// Toolbar toggle for the selected tab's SFTP panel. Separate view so it
/// observes the tab object itself (the toggle state lives on the tab).
struct FilesToggle: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState

    var body: some View {
        if let tab = window.selectedTab, tab.hasTerminalPanes {
            FilesToggleInner(tab: tab)
        } else {
            Button {} label: { Label("Files", systemImage: "folder") }
                .disabled(true)
        }
    }
}

struct FilesToggleInner: View {
    @ObservedObject var tab: SessionTab

    var body: some View {
        Toggle(isOn: $tab.showFiles) {
            Label("Files", systemImage: "folder")
        }
        .toggleStyle(.button)
        .help("Show SFTP file browser for this tab")
        .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}

struct TerminalArea: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState

    var body: some View {
        VStack(spacing: 0) {
            // Hidden in remote-desktop focus: the whole point is that the
            // remote machine gets the screen. Tabs come back on leaving focus —
            // ⌃⇧⌘F or the green button. Note that Esc is deliberately NOT an
            // exit: the remote session needs that key.
            if !window.tabs.isEmpty && !window.focusRemoteDesktop {
                TabBarView()
                Divider()
            }
            if let tab = window.selectedTab {
                TerminalPane(tab: tab)
            } else {
                EmptyStateView()
            }
        }
    }
}

struct TerminalPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: SessionTab

    var body: some View {
        // Takes over the whole tab: two file lists plus their buttons do not
        // fit beside a terminal at any useful width.
        if tab.showTransfer, tab.supportsTransfer, let panes = tab.transferPair {
            TransferPanelView(local: panes.local, remote: panes.remote,
                              controller: tab.transferController)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let local = tab.localTerminal {
            LocalTerminalHostView(tab: local)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: app.theme.backgroundColor))
                .id(tab.id)
        } else if tab.isFileBrowserOnly {
            // The panel fills the tab: there is no terminal beside it, so it
            // gets no width cap and no HSplitView divider.
            SFTPBrowserView(model: tab.sftpBrowser(), hostLabel: nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(tab.id)
        } else {
            sshBody
        }
    }

    private var sshBody: some View {
        HSplitView {
            if tab.showFiles {
                // Keyed on the focused pane's host so the panel is rebuilt —
                // and `start()` runs for the new connection — when focus moves
                // to a pane on a different machine.
                SFTPBrowserView(model: tab.sftpBrowser(), hostLabel: tab.sftpHostLabel)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 480)
                    .id(tab.focusedPane?.config.id ?? tab.config.id)
            }
            VStack(spacing: 0) {
                if tab.showSearch {
                    TerminalSearchBar(model: tab.search) {
                        tab.showSearch = false
                    }
                    Divider()
                }
                PaneNodeView(node: tab.root, tab: tab)
                    .id(tab.layoutGeneration)
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(tab.id)
    }
}

/// Recursive renderer for the split tree.
struct PaneNodeView: View {
    let node: SessionTab.Node
    @ObservedObject var tab: SessionTab
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState

    var body: some View {
        switch node {
        case .leaf(.terminal(let pane)):
            PaneLeafView(
                pane: pane,
                tab: tab,
                isFocused: tab.focusedPaneID == pane.id,
                showChrome: tab.paneCount > 1,
                onClose: { window.closePane(pane, in: tab) }
            )
        case .leaf(let content):
            // A remote desktop or a web page sharing the split with a shell.
            // The chrome is the leaf's, the content is its own view — nothing
            // here types, logs or broadcasts, which the type already says.
            NonTerminalLeafView(content: content, tab: tab)
        case .empty:
            // The gap beside a lone terminal on the last row. Plain background
            // so it reads as "nothing here", not as a broken pane.
            Color(nsColor: app.theme.backgroundColor)
                .opacity(0.35)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split(let axis, _, _, _):
            // Everything split along THIS axis becomes a sibling of one
            // container, so five panes are five equal rows rather than
            // 50/25/12.5/6.25/6.25 from nested halving. A split along the
            // other axis stays a single child and flattens on its own terms.
            let siblings = SplitLayout.siblings(of: node, axis: axis) { candidate in
                if case .split(let a, _, let first, let second) = candidate {
                    return (a, first, second)
                }
                return nil
            }
            SplitPairView(
                axis: axis,
                children: siblings.map { child in
                    AnyView(PaneNodeView(node: child, tab: tab)
                        .environmentObject(app).environmentObject(window))
                }
            )
        }
    }
}

/// A leaf that is not a terminal: a remote desktop or a web page living in the
/// split tree beside one. Deliberately thin — the close control comes from the
/// pane it wraps, and everything byte-shaped (logging, search, ZMODEM,
/// broadcast) simply does not apply to it.
struct NonTerminalLeafView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState
    let content: SessionTab.PaneContent
    let tab: SessionTab

    var body: some View {
        Group {
            switch content {
            case .vnc(let vnc): VNCPaneView(tab: vnc)
            case .rdp(let rdp): RDPPaneView(tab: rdp)
            case .web(let web): WebPaneView(tab: web)
            case .terminal: EmptyView()   // handled by PaneLeafView
            }
        }
        .frame(minWidth: 150, minHeight: 100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button { window.closePaneContent(content, in: tab) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .padding(6)
            .opacity(tab.paneCount > 1 ? 1 : 0)
        }
        .onTapGesture { tab.focusedPaneID = content.id }
        .overlay {
            if tab.focusedPaneID == content.id && tab.paneCount > 1 {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct PaneLeafView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var pane: TerminalTab
    let tab: SessionTab
    let isFocused: Bool
    let showChrome: Bool
    let onClose: () -> Void

    // Dropping a file onto the pane (P2-9): SSH panes offer SFTP or ZMODEM
    // side by side while the drag hovers; other terminals go straight to
    // ZMODEM. Kept visible while any of the three targets is hovered so the
    // overlay does not flicker as the cursor moves between zones.
    @State private var dropHover = false
    @State private var dropHoverSFTP = false
    @State private var dropHoverZModem = false

    private var themeBackground: NSColor { app.theme.backgroundColor }

    private var supportsSFTPDrop: Bool { pane.config.sessionKind == .ssh }
    private var showDropOverlay: Bool { dropHover || dropHoverSFTP || dropHoverZModem }

    var body: some View {
        VStack(spacing: 0) {
            TerminalHostView(tab: pane)
                .frame(minWidth: 150, minHeight: 100)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // App-generated status lives here, not in the scrollback (P0-2).
            PaneStatusBar(pane: pane)
        }
            .background(Color(nsColor: themeBackground))
            // File drop (P2-9). The outer target only detects hovering; the
            // overlay's zones take the actual drop.
            .onDrop(of: [.fileURL], isTargeted: $dropHover) { _ in false }
            .overlay {
                if showDropOverlay {
                    HStack(spacing: 1) {
                        if supportsSFTPDrop {
                            dropZone("Upload via SFTP", icon: "arrow.up.doc",
                                     hover: $dropHoverSFTP) { urls in
                                // The SFTP panel follows the focused pane, so
                                // focus the drop target before uploading.
                                tab.focusedPaneID = pane.id
                                tab.sftpBrowser().uploadItems(urls)
                            }
                        }
                        dropZone("Send via ZMODEM", icon: "arrow.up.circle",
                                 hover: $dropHoverZModem) { urls in
                            // ZMODEM moves one file per transfer.
                            if let first = urls.first { pane.sendFileViaZModem(first) }
                        }
                    }
                    .background(Color.black.opacity(0.45))
                }
            }
            // Dimming goes on FIRST: a later overlay draws on top, and putting
            // this after the badge greyed out the very control you need to
            // click to bring the pane back.
            .overlay {
                if app.broadcastInput && !pane.receivesBroadcast {
                    Color.black.opacity(0.3).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    // Chosen here rather than in a menu at the top of the
                    // window: the thing you are including is the pane you are
                    // looking at.
                    if app.broadcastInput {
                        Button {
                            pane.receivesBroadcast.toggle()
                        } label: {
                            Image(systemName: pane.receivesBroadcast
                                  ? "antenna.radiowaves.left.and.right"
                                  : "antenna.radiowaves.left.and.right.slash")
                                .foregroundStyle(pane.receivesBroadcast
                                                 ? Color.blue : Color.orange)
                                .padding(3)
                                .background(.black.opacity(0.35), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(pane.receivesBroadcast
                              ? "Receiving broadcast input — click to leave it out"
                              : "Not receiving broadcast input — click to include it")
                    }
                    if showChrome {
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help("Close pane")
                    }
                }
                .padding(4)
            }
            // Which panes are in the broadcast, as a colour you can see
            // without reading anything: blue edge for in, orange for out.
            // Only while broadcast is on — the rest of the time the border
            // means focus and nothing else.
            .overlay {
                if app.broadcastInput {
                    Rectangle()
                        .strokeBorder(pane.receivesBroadcast
                                      ? Color.blue.opacity(0.8)
                                      : Color.orange.opacity(0.65),
                                      lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            // Green means "this is where your typing goes". Drawn inside the
            // broadcast border so both are legible when a focused pane is also
            // in the group.
            .overlay {
                if showChrome && isFocused {
                    Rectangle()
                        .strokeBorder(Color.green.opacity(0.9), lineWidth: 2)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if case .closed = pane.state {
                    VStack(spacing: 10) {
                        Text("Connection closed")
                            .foregroundStyle(.white.opacity(0.85))
                        Button {
                            pane.connect()
                        } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        // Both ways out, said where you are looking when you
                        // need them.
                        Text("Return to reconnect · Esc to close")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(20)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                }
            }
    }

    /// One landing zone of the drop overlay. Its own drop target, so during
    /// the drag the two halves choose the transfer without a dialog after.
    private func dropZone(_ title: String, icon: String,
                          hover: Binding<Bool>,
                          action: @escaping ([URL]) -> Void) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.callout)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hover.wrappedValue ? Color.accentColor.opacity(0.55) : .clear)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: hover) { providers in
            loadFileURLs(from: providers) { urls in
                guard !urls.isEmpty else { return }
                action(urls)
            }
            return true
        }
        .accessibilityLabel(title)
    }

    /// Resolve dragged items to file URLs on the main queue.
    private func loadFileURLs(from providers: [NSItemProvider],
                              completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

struct TabBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState
    /// Which tab is being dragged, so it can be dimmed while it moves.
    @State private var dragging: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(window.tabs) { tab in
                    TabChip(tab: tab, selected: tab.id == window.selectedTabID)
                        .opacity(dragging == tab.id ? 0.4 : 1)
                        .onDrag {
                            dragging = tab.id
                            // The payload is only an identifier: the tab object
                            // itself never leaves the window, because its
                            // terminal view cannot live in two places.
                            return NSItemProvider(object: tab.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text],
                                delegate: TabReorderDropDelegate(
                                    target: tab.id, window: window, dragging: $dragging))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(.bar)
    }
}

/// Reorders as the drag passes over a chip, rather than only on release, so the
/// tab bar shows where the tab will land while you are still holding it.
private struct TabReorderDropDelegate: DropDelegate {
    let target: UUID
    let window: WindowState
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        window.moveTab(id: dragging, before: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // The reordering already happened on the way in; this just ends it.
        dragging = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}

/// "This tab is waiting for you." A still dot in a row of tabs is easy to miss,
/// so it pings outward like a radar sweep — but the dot underneath stays solid
/// the whole time, because it is a status indicator and a status you can only
/// read at the right moment is worse than a quiet one.
private struct AttentionDot: View {
    @State private var pinging = false

    /// Someone who has asked the system for less motion should not be handed a
    /// permanently animating window; they get a halo instead of a sweep.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        Circle()
            .fill(Color.blue)
            .frame(width: 7, height: 7)
            .overlay {
                Circle()
                    .stroke(Color.blue, lineWidth: 1.5)
                    .scaleEffect(pinging ? 2.4 : 1)
                    .opacity(pinging ? 0 : 0.7)
            }
            .accessibilityLabel("needs attention")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    pinging = true
                }
            }
    }
}

struct TabChip: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState
    @ObservedObject var tab: SessionTab
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Image(systemName: tab.isLocal ? "apple.terminal" : tab.kind.symbolName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .lineLimit(1)
                .font(.callout)
            // A pane in this tab wants the user (bell / resumed output).
            if tab.attentionCount > 0 {
                AttentionDot()
            }
            Button {
                window.closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { window.selectedTabID = tab.id }
    }

    private var statusColor: Color {
        switch tab.aggregateState {
        case .connecting: return .yellow
        case .connected: return .green
        case .closed: return .red
        }
    }
}

/// The detail area with nothing open (P2-10). Two flavours: a brand-new vault
/// gets the three ways in (create, import, discover); a vault with saved
/// sessions gets pointed back at them.
struct EmptyStateView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState
    @State private var showNewSession = false
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            if app.data.sessions.isEmpty {
                Text("Welcome to MacMoba")
                    .font(.title3)
                Text("Connections live in the sidebar. Start with one of these:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("New Session…") { showNewSession = true }
                        .keyboardShortcut(.defaultAction)
                    Button("Import from Other Apps…") { showImporter = true }
                    Button("Discover on Network…") { window.showDiscover = true }
                }
                .padding(.top, 4)
            } else {
                Text("No open sessions")
                    .font(.title3)
                Text("Double-click a session in the sidebar, or press ⌘K to quick-connect")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showNewSession) {
            SessionEditView(original: nil) { app.upsertSession($0) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let n = app.importSessions(from: url)
                if n > 0 {
                    app.infoMessage = "Imported \(n) session\(n == 1 ? "" : "s") "
                        + "from \(url.lastPathComponent)."
                }
            }
        }
    }
}

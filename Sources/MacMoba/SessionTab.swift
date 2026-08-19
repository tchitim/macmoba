// One tab = a binary tree of terminal panes (MobaXterm/iTerm-style splits),
// all sharing the same session config, plus the tab-level SFTP browser.

import Combine
import Foundation
import MacMobaCore
import SwiftUI

@MainActor
final class SessionTab: ObservableObject, Identifiable {
    enum Node {
        case leaf(TerminalTab)
        /// A gap in the grid. The last row of an odd number of sessions holds
        /// one of these so the lone terminal keeps the SAME width as the ones
        /// above it instead of stretching across the window.
        case empty(id: UUID)
        indirect case split(axis: Axis, id: UUID, first: Node, second: Node)
    }

    let id = UUID()
    let config: SessionConfig
    /// Local shell tab (MobaXterm-style); nil for SSH tabs.
    let localTerminal: LocalTerminalTab?
    /// VNC tab; nil for every other kind. Mirrors localTerminal: a whole-tab
    /// alternative to the SSH pane tree rather than a pane inside it.
    let vnc: VNCTab?
    /// RDP tab; same arrangement as vnc.
    let rdp: RDPTab?
    /// Web tab: a page reached through an SSH session. Like vnc/rdp it owns
    /// the whole tab rather than living in the pane tree.
    let web: WebTab?
    /// True for a tab that is nothing but a file browser (FTP). Like vnc/rdp
    /// it has no pane tree, so splits, broadcast, logging and search do not
    /// apply — but unlike them the browser panel is the whole content, not an
    /// optional sidebar, so it cannot be closed away to leave an empty tab.
    let isFileBrowserOnly: Bool
    @Published private(set) var root: Node
    @Published var focusedPaneID: UUID?
    @Published var showFiles = false
    /// Two-pane transfer view, replacing the tab's content while it is on.
    @Published var showTransfer = false
    @Published var showSearch = false
    let search = TerminalSearchModel()
    /// Bumped on every split-tree change; the view keys split containers on it
    /// so dividers reset to an even 50/50 after add/remove/merge.
    @Published private(set) var layoutGeneration = 0

    private weak var app: AppState?
    private var paneObservers: [UUID: AnyCancellable] = [:]
    /// Observer for a whole-tab child (VNC or local shell), which lives outside
    /// the pane tree and so is not covered by paneObservers.
    private var childObserver: AnyCancellable?
    /// One file browser per host in this tab, keyed by session id: a tab can
    /// hold panes on several machines, and each needs its own SFTP connection.
    private var sftpModels: [String: SFTPBrowserModel] = [:]

    init(config: SessionConfig, app: AppState) {
        self.config = config
        self.app = app
        self.localTerminal = nil
        self.vnc = nil
        self.rdp = nil
        self.web = nil
        self.isFileBrowserOnly = false
        let pane = TerminalTab(config: config, app: app)
        root = .leaf(pane)
        focusedPaneID = pane.id
        register(pane)
        pane.connect()
    }

    /// A tab built around a pane that is already connected.
    ///
    /// The counterpart to `merge`: used when panes are split back out into
    /// separate tabs. The pane is adopted as-is — no reconnect, no lost
    /// scrollback.
    init(adopting pane: TerminalTab, app: AppState) {
        self.config = pane.config
        self.app = app
        self.localTerminal = nil
        self.vnc = nil
        self.rdp = nil
        self.web = nil
        self.isFileBrowserOnly = false
        root = .leaf(pane)
        focusedPaneID = pane.id
        register(pane)
    }

    /// Take a pane out of this tab's tree WITHOUT disconnecting it, so it can
    /// be adopted elsewhere. Returns false when it was the last one.
    func detach(_ pane: TerminalTab) -> Bool {
        guard panes.count > 1, let newRoot = Self.removing(root, paneID: pane.id) else {
            return false
        }
        paneObservers[pane.id] = nil
        root = newRoot
        if focusedPaneID == pane.id { focusedPaneID = panes.first?.id }
        settleLayout()
        return true
    }

    /// Local shell tab: no SSH, no split tree — just this Mac's login shell.
    init(localShellIn directory: String?, app: AppState) {
        self.config = SessionConfig(name: "Local", host: "localhost", username: NSUserName())
        self.app = app
        let local = LocalTerminalTab(app: app)
        self.localTerminal = local
        self.vnc = nil
        self.rdp = nil
        self.web = nil
        self.isFileBrowserOnly = false
        // Placeholder leaf keeps the Node tree non-optional; it is never shown
        // for local tabs (ContentView renders localTerminal instead).
        root = .leaf(TerminalTab(config: config, app: app))
        childObserver = local.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        local.start(directory: directory)
    }

    /// VNC tab: no pane tree, no SFTP — just the framebuffer.
    init(vnc config: SessionConfig, app: AppState) {
        self.config = config
        self.app = app
        self.localTerminal = nil
        let vncTab = VNCTab(config: config, app: app)
        self.vnc = vncTab
        self.rdp = nil
        self.web = nil
        self.isFileBrowserOnly = false
        // Placeholder leaf keeps the Node tree non-optional; never rendered.
        root = .leaf(TerminalTab(config: config, app: app))
        // Re-publish the VNC tab's changes: the tab chip's title and status dot
        // read through this object, and VNC state arrives asynchronously.
        childObserver = vncTab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        vncTab.connect()
    }

    /// RDP tab: no pane tree, no SFTP — just the framebuffer.
    init(rdp config: SessionConfig, app: AppState) {
        self.config = config
        self.app = app
        self.localTerminal = nil
        self.vnc = nil
        let rdpTab = RDPTab(config: config, app: app)
        self.rdp = rdpTab
        self.web = nil
        self.isFileBrowserOnly = false
        root = .leaf(TerminalTab(config: config, app: app))
        childObserver = rdpTab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        rdpTab.connect()
    }

    /// File-browser tab (FTP): no terminal, no screen — the browser panel is
    /// the whole tab.
    init(files config: SessionConfig, app: AppState) {
        self.config = config
        self.app = app
        self.localTerminal = nil
        self.vnc = nil
        self.rdp = nil
        self.web = nil
        self.isFileBrowserOnly = true
        // Placeholder leaf keeps the Node tree non-optional; never rendered.
        root = .leaf(TerminalTab(config: config, app: app))
        // Shown straight away rather than behind the toolbar toggle: hiding it
        // would leave a tab with nothing in it at all.
        showFiles = true
    }

    /// Web tab: a page, opened through an SSH session when one is chosen.
    init(web config: SessionConfig, app: AppState) {
        self.config = config
        self.app = app
        self.localTerminal = nil
        self.vnc = nil
        self.rdp = nil
        self.isFileBrowserOnly = false
        let webTab = WebTab(config: config, app: app)
        self.web = webTab
        root = .leaf(TerminalTab(config: config, app: app))
        childObserver = webTab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Pane access

    /// ⚠️ For a VNC, RDP or local-shell tab this is **not** empty: those tabs
    /// keep a never-connected placeholder leaf so `root` can be non-optional,
    /// and it shows up here. Check `isSinglePane` before treating the result as
    /// real terminals — several bugs have come from not doing so (splitting into
    /// an RDP tab, merging one away, logging a pane that receives no bytes).
    var panes: [TerminalTab] {
        Self.collect(root)
    }

    /// ⚠️ Same caveat as `panes`: on a single-pane tab this returns the
    /// placeholder, not nil.
    var focusedPane: TerminalTab? {
        let all = panes
        return all.first { $0.id == focusedPaneID } ?? all.first
    }

    var isLocal: Bool { localTerminal != nil }

    /// What this tab is, for the chip's icon. Local shells are terminals too.
    var kind: SessionKind {
        if vnc != nil { return .vnc }
        if rdp != nil { return .rdp }
        if web != nil { return .web }
        if isFileBrowserOnly { return .ftp }
        return .ssh
    }
    var isVNC: Bool { vnc != nil }
    var isRDP: Bool { rdp != nil }
    /// True when this tab has no SSH pane tree, so splits/SFTP/logging do not apply.
    var isSinglePane: Bool {
        localTerminal != nil || vnc != nil || rdp != nil || web != nil || isFileBrowserOnly
    }

    var title: String {
        if let localTerminal { return localTerminal.title }
        if let vnc { return vnc.title }
        if let rdp { return rdp.title }
        if let web { return web.title }
        if isFileBrowserOnly { return config.name }
        let base = focusedPane?.title ?? config.name
        let count = panes.count
        return count > 1 ? "\(base) ▦\(count)" : base
    }

    /// Best state across panes, for the tab chip's status dot.
    /// The on-screen view the Overview thumbnails, or nil for a file browser.
    var snapshotView: NSView? {
        if let localTerminal { return localTerminal.termView }
        if let vnc { return vnc.container }
        if let rdp { return rdp.container }
        if let web { return web.webView }
        return focusedPane?.termView
    }

    /// A bitmap of the current view for the Overview, or nil when it is not laid
    /// out on screen yet (a background tab in a window that was never shown).
    func snapshot() -> NSImage? {
        guard let view = snapshotView, view.window != nil,
              view.bounds.width > 1, view.bounds.height > 1 else { return nil }
        // A remote desktop hands us a finished frame and assigns it straight to
        // `layer.contents`; it has no `draw(_:)` for `cacheDisplay` to replay,
        // so that path yields an empty card. The frame we want IS that image.
        if vnc != nil || rdp != nil, let framebuffer = framebufferImage(in: view) {
            return framebuffer
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// The displayed frame of a layer-hosted remote desktop, found by walking
    /// down to whichever layer actually carries a CGImage — the framebuffer
    /// view is a child of the container, and it is the child that holds it.
    private func framebufferImage(in view: NSView) -> NSImage? {
        var pending: [CALayer] = view.layer.map { [$0] } ?? []
        while let layer = pending.popLast() {
            // `as? CGImage` always succeeds on a CF type, so ask the runtime.
            if let contents = layer.contents,
               CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let frame = contents as! CGImage
                // Sized to the view, not the frame: the remote desktop may be a
                // different resolution, and the card wants what is on screen.
                return NSImage(cgImage: frame, size: view.bounds.size)
            }
            pending.append(contentsOf: layer.sublayers ?? [])
        }
        return nil
    }

    var aggregateState: TerminalTab.State {
        if let localTerminal { return localTerminal.state }
        if let vnc { return vnc.state }
        if let rdp { return rdp.state }
        if let web { return web.state }
        if isFileBrowserOnly { return fileBrowserState }
        let states = panes.map(\.state)
        if states.contains(.connected) { return .connected }
        if states.contains(.connecting) { return .connecting }
        return states.first ?? .closed("no panes")
    }

    // MARK: - Split / close

    /// Split the focused pane with a NEW connection. By default duplicates the
    /// focused pane's session; pass a config to connect somewhere else.
    func splitFocused(_ axis: Axis, config newConfig: SessionConfig? = nil) {
        guard let app, let target = focusedPane else { return }
        let paneConfig = newConfig ?? target.config
        // A pane is a terminal, so it can only ever hold an SSH session. Handed
        // a VNC or RDP config it would open *SSH* to the remote-desktop port and
        // sit there connecting forever, which reads as a blank pane. The menus
        // do not offer those, but this is the guarantee itself rather than a
        // property of one menu.
        guard paneConfig.sessionKind.fitsInSplitPane, !isSinglePane else { return }
        let newPane = TerminalTab(config: paneConfig, app: app)
        register(newPane)
        root = Self.replacing(root, paneID: target.id) { leaf in
            .split(axis: axis, id: UUID(), first: leaf, second: .leaf(newPane))
        }
        focusedPaneID = newPane.id
        newPane.connect()
        settleLayout()
    }

    /// Adopt another tab's live pane tree next to the focused pane —
    /// no reconnect, the terminals move as-is.
    func merge(node: Node, panes incoming: [TerminalTab], axis: Axis) {
        guard let target = focusedPane, !incoming.isEmpty else { return }
        for pane in incoming { register(pane) }
        root = Self.replacing(root, paneID: target.id) { leaf in
            .split(axis: axis, id: UUID(), first: leaf, second: node)
        }
        focusedPaneID = incoming.first?.id
        settleLayout()
    }

    /// After a split-tree change, once SwiftUI has re-laid the panes:
    /// re-sync every remote PTY to its (possibly re-parented) view size and
    /// give keyboard focus back to the focused pane.
    /// Rebuild the pane tree as a grid of rows, two panes across.
    ///
    /// Two per row because a terminal needs width — 80 columns of text is the
    /// whole point — so a fifth session goes onto a new row rather than being
    /// stretched down the side of the window.
    ///
    /// The panes themselves are untouched — only the tree around them changes,
    /// so nothing reconnects and no scrollback is lost.
    func tileIntoGrid() {
        // De-duplicated by id: a pane's terminal is ONE AppKit view, so if the
        // same pane were ever to appear twice in the tree, only one copy could
        // draw and the other would be a blank rectangle you cannot type into.
        var seen = Set<UUID>()
        let existing = panes.filter { seen.insert($0.id).inserted }
        guard existing.count > 1 else { return }
        let rows = GridLayout.rows(for: existing.count).map { indices -> Node in
            var cells = indices.map { Node.leaf(existing[$0]) }
            // Pad a short last row so its terminal keeps the same width as the
            // ones above rather than spanning the whole window.
            while cells.count < GridLayout.panesPerRow {
                cells.append(.empty(id: UUID()))
            }
            return Self.stack(cells, axis: .horizontal)
        }
        root = Self.stack(rows, axis: .vertical)
        settleLayout()
    }

    /// Fold nodes into a chain of splits along one axis. The nesting shape does
    /// not matter for sizing: the renderer flattens same-axis chains into one
    /// container, which is what makes them share the space equally.
    private static func stack(_ nodes: [Node], axis: Axis) -> Node {
        // An empty list would have crashed here; a gap is the sane answer.
        guard var result = nodes.last else { return .empty(id: UUID()) }
        for node in nodes.dropLast().reversed() {
            result = .split(axis: axis, id: UUID(), first: node, second: result)
        }
        return result
    }

    /// Redistribute the panes evenly and let the terminals catch up.
    ///
    /// Public so switching MultiExec on can tidy the layout: broadcasting to
    /// panes you cannot read is not much use, and that is the moment people
    /// want them all the same size.
    func rebalance() { settleLayout() }

    private func settleLayout() {
        layoutGeneration += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            for pane in self.panes { pane.syncRemoteSize() }
            if let focused = self.focusedPane {
                focused.termView.window?.makeFirstResponder(focused.termView)
            }
        }
    }

    /// Detach bookkeeping before this tab's panes are adopted by another tab.
    /// Panes stay connected; only tab-level state is torn down.
    func prepareForMerge() {
        paneObservers.removeAll()
        closeSFTPBrowsers()
    }

    /// Close one pane. Returns false when it was the last pane —
    /// the caller should close the whole tab instead.
    func closePane(_ pane: TerminalTab) -> Bool {
        guard panes.count > 1 else { return false }
        pane.disconnect()
        paneObservers[pane.id] = nil
        if let newRoot = Self.removing(root, paneID: pane.id) {
            root = newRoot
        }
        if focusedPaneID == pane.id { focusedPaneID = panes.first?.id }
        settleLayout()
        return true
    }

    func disconnectAll() {
        localTerminal?.disconnect()
        vnc?.disconnect()
        rdp?.disconnect()
        web?.disconnect()
        for pane in panes { pane.disconnect() }
        paneObservers.removeAll()
        closeSFTPBrowsers()
    }

    private func closeSFTPBrowsers() {
        closeTransferPanes()
        for model in sftpModels.values { model.close() }
        sftpModels.removeAll()
    }

    // MARK: - Two-pane transfer

    private var transferLocal: TransferPaneModel?
    private var transferRemote: TransferPaneModel?
    private(set) lazy var transferController = TransferController()

    /// True when this tab can move files at all: it needs a session whose
    /// credentials open a file service. A local shell, VNC or RDP tab cannot.
    var supportsTransfer: Bool {
        guard localTerminal == nil, vnc == nil, rdp == nil else { return false }
        return transferConfig.sessionKind == .ftp
            || transferConfig.sessionKind.authenticatesOverSSH
    }

    /// Which session the remote pane connects to: the focused pane's, for the
    /// same reason the file browser follows it.
    private var transferConfig: SessionConfig {
        isFileBrowserOnly ? config : (focusedPane?.config ?? config)
    }

    /// The two panes, once `prepareTransfer()` has built them.
    ///
    /// Read-only on purpose: building them from inside a view's `body` would
    /// be mutating state during a view update, which SwiftUI is entitled to
    /// loop on. The toggle calls `prepareTransfer()` instead.
    private(set) var transferPair: (local: TransferPaneModel, remote: TransferPaneModel)?

    func prepareTransfer() {
        if let transferLocal, let transferRemote,
           transferRemote.title == transferTitle(for: transferConfig) {
            transferPair = (transferLocal, transferRemote)
            return
        }
        // The remote pane is rebuilt when the focused pane moves to another
        // host, so the two sides never disagree about which server is which.
        transferRemote?.close()
        let config = transferConfig
        let hostKeys = app?.hostKeyVerification
        // Same route the terminal takes.
        let jumps = app?.jumpChain(for: config) ?? []
        let local = transferLocal ?? TransferPaneModel(
            title: "This Mac", isLocal: true, connect: { LocalFileService() })
        let remote = TransferPaneModel(
            title: transferTitle(for: config), isLocal: false,
            connect: { () -> RemoteFileService in
                let resolved = try await SecretResolver.resolve(session: config)
                if config.sessionKind == .ftp {
                    return try await FTPClient.connect(config: resolved)
                }
                return try await SFTPClient.connect(
                    config: resolved,
                    via: try await SecretResolver.resolve(sessions: jumps),
                    hostKeys: hostKeys)
            })
        transferLocal = local
        transferRemote = remote
        transferPair = (local, remote)
        objectWillChange.send()
    }

    private func transferTitle(for config: SessionConfig) -> String {
        config.username.isEmpty
            ? "\(config.name) · \(config.host)"
            : "\(config.name) · \(config.username)@\(config.host)"
    }

    private func closeTransferPanes() {
        transferLocal?.close()
        transferRemote?.close()
        transferLocal = nil
        transferRemote = nil
        transferPair = nil
    }

    // MARK: - SFTP browser (tab level)

    /// The file browser for whichever pane has focus.
    ///
    /// It used to be built from the TAB's config, which is only the session the
    /// tab was opened with. Split a pane to another host and the panel kept
    /// listing the first one — so the files shown belonged to a different
    /// machine than the terminal right next to them, with nothing on screen
    /// saying so. That is worst with broadcast input on, where several hosts
    /// are being typed into at once and an upload still goes to exactly one.
    ///
    /// One connection per host is kept, so moving focus back and forth does not
    /// reconnect each time.
    func sftpBrowser() -> SFTPBrowserModel {
        // A file-browser tab has no panes to follow — the tab IS the session.
        let paneConfig = isFileBrowserOnly ? config : (focusedPane?.config ?? config)
        if let existing = sftpModels[paneConfig.id] { return existing }
        let model = SFTPBrowserModel(config: paneConfig,
                                     jumps: app?.jumpChain(for: paneConfig) ?? [],
                                     hostKeys: app?.hostKeyVerification)
        sftpModels[paneConfig.id] = model
        // A file-browser tab has no pane to report connect/failure through, so
        // the chip's status dot reads the panel's own state — which only
        // updates if its changes are re-published here.
        if isFileBrowserOnly {
            childObserver = model.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        return model
    }

    /// The status dot for a file-browser tab mirrors its one connection.
    private var fileBrowserState: TerminalTab.State {
        guard let model = sftpModels[config.id] else { return .connecting }
        switch model.state {
        case .connecting: return .connecting
        case .ready: return .connected
        case .failed(let message): return .closed(message)
        }
    }

    /// Which host the file browser is showing, for its header. Nil when there
    /// is only one host in the tab and the question cannot arise.
    var sftpHostLabel: String? {
        guard !isFileBrowserOnly else { return nil }
        let configs = Set(panes.map(\.config.id))
        guard configs.count > 1 else { return nil }
        let shown = focusedPane?.config ?? config
        // The session's name leads: that is what the sidebar calls it, and two
        // sessions can share a host (a jump host, or two ports on one machine)
        // where "user@host" alone would name them identically.
        let target = shown.username.isEmpty ? shown.host : "\(shown.username)@\(shown.host)"
        return shown.name.isEmpty ? target : "\(shown.name) · \(target)"
    }

    /// Panes waiting for the user (bell / resumed output). Drives the tab
    /// badge and ⌥⌘U.
    var attentionCount: Int {
        panes.filter(\.needsAttention).count
            + (localTerminal?.needsAttention == true ? 1 : 0)
    }

    // MARK: - Internals

    private func register(_ pane: TerminalTab) {
        // Re-publish child changes (title, state) so chips and borders update.
        paneObservers[pane.id] = pane.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        pane.onFocused = { [weak self, weak pane] in
            // Looking at the pane IS the attention — clear its badge.
            pane?.clearAttention()
            guard let self, let pane, self.focusedPaneID != pane.id else { return }
            self.focusedPaneID = pane.id
        }
    }

    private static func collect(_ node: Node) -> [TerminalTab] {
        switch node {
        case .leaf(let pane):
            return [pane]
        case .empty:
            return []
        case .split(_, _, let first, let second):
            return collect(first) + collect(second)
        }
    }

    private static func replacing(_ node: Node, paneID: UUID,
                                  with transform: (Node) -> Node) -> Node {
        switch node {
        case .leaf(let pane):
            return pane.id == paneID ? transform(node) : node
        case .empty:
            return node
        case .split(let axis, let id, let first, let second):
            return .split(axis: axis, id: id,
                          first: replacing(first, paneID: paneID, with: transform),
                          second: replacing(second, paneID: paneID, with: transform))
        }
    }

    /// Remove the leaf; a split with one side removed collapses to the other.
    /// Returns nil when the node itself was the removed leaf.
    private static func removing(_ node: Node, paneID: UUID) -> Node? {
        switch node {
        case .leaf(let pane):
            return pane.id == paneID ? nil : node
        case .empty:
            // A gap only exists to hold a space next to a real pane. Once the
            // tree is rebuilt without that pane, the gap must go too, or the
            // tab keeps a blank rectangle nobody can close.
            return nil
        case .split(let axis, let id, let first, let second):
            let newFirst = removing(first, paneID: paneID)
            let newSecond = removing(second, paneID: paneID)
            switch (newFirst, newSecond) {
            case (nil, let s?): return s
            case (let f?, nil): return f
            case (let f?, let s?): return .split(axis: axis, id: id, first: f, second: s)
            case (nil, nil): return nil
            }
        }
    }
}

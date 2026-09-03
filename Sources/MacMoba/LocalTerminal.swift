// Local shell tab — MobaXterm's local terminal. Runs the user's login shell
// on this Mac instead of over SSH, in the same tab/split machinery.

import AppKit
import MacMobaCore
import SwiftTerm
import SwiftUI

/// Owns the PTY itself rather than letting the terminal view own it.
///
/// `LocalProcessTerminalView` bundles a shell into a SwiftTerm view, which was
/// the shortest path while SwiftTerm was the only engine. It also means the
/// shell can only exist inside that one view. Holding a plain `LocalProcess`
/// instead puts the local shell on the same footing as an SSH session: bytes
/// in, bytes out, and the seam decides who draws them.
///
/// The dead-shell keys moved with it. They used to be a `send` override on a
/// SwiftTerm subclass; as an input callback they are engine-agnostic, and
/// still go through the same `DeadTerminalKey` an SSH pane uses, because one
/// convention implemented twice is two conventions.
@MainActor
final class LocalTerminalTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    /// SwiftTerm's view, kept for the callers not yet behind the seam (themes,
    /// the clipboard menu). Nil-checked rather than assumed: with the
    /// libghostty engine there is no SwiftTerm view at all.
    let termView: TerminalView?
    let engine: any TerminalEngineView

    @Published var title = "Local"
    @Published var state: TerminalTab.State = .connecting
    /// An agent hook (agent-event) flagged this tab; cleared when it is viewed.
    @Published private(set) var needsAttention = false

    private weak var app: AppState?
    private let bridge = LocalShellBridge()
    private let process: LocalProcess

    init(app: AppState) {
        self.app = app
        let bridge = self.bridge
        process = LocalProcess(delegate: bridge)
        if TerminalDefaults.usesGhosttyEngine() {
            termView = nil
            engine = GhosttyEngine()
        } else {
            let view = ClipboardTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
            termView = view
            // No owner set on purpose: `owner` is how the clipboard finds an
            // SSH tab to upload a pasted image to, and a local shell has
            // nowhere to upload to — the file would already be on this Mac.
            engine = SwiftTermEngine(view: view)
        }
        engine.engineSetScrollback(TerminalDefaults.scrollback())
        if let termView { TerminalRendering.apply(to: termView) }
        super.init()

        bridge.onData = { [weak self] slice in
            Task { @MainActor in self?.engine.engineFeed(slice) }
        }
        bridge.onExit = { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                self.state = .closed(code.map { "exit \($0)" } ?? "closed")
                self.engine.engineFeed(
                    ArraySlice(Array("\r\n\u{1b}[90m[shell exited]\u{1b}[0m\r\n".utf8)))
            }
        }
        bridge.windowSize = { [weak self] in
            guard let self else { return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
            let grid = MainActor.assumeIsolated { self.engine.engineGrid }
            return winsize(ws_row: UInt16(grid.rows), ws_col: UInt16(grid.cols),
                           ws_xpixel: 0, ws_ypixel: 0)
        }

        engine.engineOnInput = { [weak self] data in
            guard let self else { return }
            if self.handleKeyAtDeadShell(Array(data)) { return }
            self.process.send(data: data)
        }
        engine.engineOnResize = { [weak self] cols, rows in
            guard let self, self.process.childfd >= 0 else { return }
            var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols),
                               ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.process.childfd, TIOCSWINSZ, &size)
        }
        engine.engineOnTitle = { [weak self] title in
            Task { @MainActor in self?.title = title.isEmpty ? "Local" : title }
        }

        applyFont(size: app.terminalFontSize)
        engine.engineApplyTheme(app.theme)
    }

    func start(directory: String? = nil) {
        // The user's login shell, launched as a login shell so their profile runs.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = (shell as NSString).lastPathComponent
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        // Agent hooks running in this shell can address their own tab, and
        // find the CLI without PATH games.
        env.append("MACMOBA_TAB=\(id.uuidString)")
        if let cli = Bundle.main.resourceURL?
            .appendingPathComponent("bin/macmoba").path,
           FileManager.default.isExecutableFile(atPath: cli) {
            env.append("MACMOBA_CLI=\(cli)")
        }
        state = .connected
        process.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: "-\(name)",
            currentDirectory: directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// Keys typed at a dead shell. Returns true when the keystroke was one of
    /// the two ways out, so it is swallowed instead of written to a PTY that no
    /// longer exists.
    ///
    /// Same policy object as an SSH pane, deliberately: "Return reconnects, Esc
    /// closes" is one convention, and a second implementation of it is how the
    /// two drift apart.
    func handleKeyAtDeadShell(_ bytes: [UInt8]) -> Bool {
        guard case .closed = state else { return false }
        switch DeadTerminalKey.action(for: bytes) {
        case .reconnect:
            // A fresh shell in the same view, so the scrollback above the
            // "[shell exited]" line is still there to scroll back through.
            start()
            return true
        case .close:
            app?.closePaneHoldingDeadShell(self)
            return true
        case .ignore:
            return true
        }
    }

    func disconnect() {
        process.terminate()
        state = .closed("closed")
    }

    func applyFont(size: Double) {
        engine.engineSetFontSize(size)
    }

    func markAttention() { needsAttention = true }
    func clearAttention() { if needsAttention { needsAttention = false } }
}

/// The PTY side, off the main actor because LocalProcess delivers on its own
/// queue. Same reason the experimental panes have one.
private final class LocalShellBridge: NSObject, LocalProcessDelegate, @unchecked Sendable {
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var windowSize: (() -> winsize)?

    func dataReceived(slice: ArraySlice<UInt8>) { onData?(slice) }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { onExit?(exitCode) }
    func getWindowSize() -> winsize {
        windowSize?() ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }
}


struct LocalTerminalHostView: NSViewRepresentable {
    let tab: LocalTerminalTab
    /// Called when this pane takes the keyboard, so the focus ring and the
    /// tab's idea of the focused pane follow the click — the same wiring an
    /// SSH pane has. A SwiftUI tap gesture cannot do this: the terminal view
    /// consumes the click before SwiftUI sees it.
    var onFocus: () -> Void = {}

    /// The same self-healing container an SSH pane uses, for the same reason.
    ///
    /// This used to hand SwiftUI the terminal view itself, which was safe only
    /// while a local shell was a whole tab and never moved. Now that it is an
    /// ordinary pane it gets re-parented — breaking a split apart builds a new
    /// host for the same view — and a bare view goes wherever the LAST host
    /// put it. If SwiftUI then keeps an earlier host on screen, the pane draws
    /// nothing: right border, right title, blank middle.
    func makeNSView(context: Context) -> PaneContainerView {
        let container = PaneContainerView(termView: tab.engine.engineView)
        container.onFocusGained = onFocus
        container.onEnteredWindow = { [weak tab] in tab?.engine.engineTakeFocus() }
        return container
    }

    func updateNSView(_ nsView: PaneContainerView, context: Context) {
        nsView.adoptTerminal()
    }
}

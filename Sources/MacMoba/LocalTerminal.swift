// Local shell tab — MobaXterm's local terminal. Runs the user's login shell
// on this Mac instead of over SSH, in the same tab/split machinery.

import AppKit
import MacMobaCore
import SwiftTerm
import SwiftUI

@MainActor
final class LocalTerminalTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let termView: LocalProcessTerminalView

    @Published var title = "Local"
    @Published var state: TerminalTab.State = .connecting
    /// An agent hook (agent-event) flagged this tab; cleared when it is viewed.
    @Published private(set) var needsAttention = false

    private weak var app: AppState?

    init(app: AppState) {
        self.app = app
        termView = ClipboardLocalTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        termView.getTerminal().changeScrollback(TerminalDefaults.scrollback())
        TerminalRendering.apply(to: termView)
        super.init()
        termView.processDelegate = self
        applyFont(size: app.terminalFontSize)
        app.theme.apply(to: termView)
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
        termView.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: "-\(name)",
            currentDirectory: directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    func disconnect() {
        // Terminating the shell tears down the PTY.
        if let pid = termView.process?.shellPid {
            kill(pid, SIGHUP)
        }
        state = .closed("closed")
    }

    func applyFont(size: Double) {
        termView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func markAttention() { needsAttention = true }
    func clearAttention() { if needsAttention { needsAttention = false } }
}

extension LocalTerminalTab: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in
            self.title = title.isEmpty ? "Local" : title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.state = .closed(exitCode.map { "exit \($0)" } ?? "closed")
            source.feed(text: "\r\n\u{1b}[90m[shell exited]\u{1b}[0m\r\n")
        }
    }
}

struct LocalTerminalHostView: NSViewRepresentable {
    let tab: LocalTerminalTab

    /// The same self-healing container an SSH pane uses, for the same reason.
    ///
    /// This used to hand SwiftUI the terminal view itself, which was safe only
    /// while a local shell was a whole tab and never moved. Now that it is an
    /// ordinary pane it gets re-parented — breaking a split apart builds a new
    /// host for the same view — and a bare view goes wherever the LAST host
    /// put it. If SwiftUI then keeps an earlier host on screen, the pane draws
    /// nothing: right border, right title, blank middle.
    func makeNSView(context: Context) -> PaneContainerView {
        let container = PaneContainerView(termView: tab.termView)
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(container.termView)
        }
        return container
    }

    func updateNSView(_ nsView: PaneContainerView, context: Context) {
        nsView.adoptTerminal()
    }
}

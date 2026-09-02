// EXPERIMENTAL: a local shell drawn by libghostty instead of SwiftTerm.
//
// This exists to be compared, not to replace anything. Open one beside an
// ordinary local terminal (⌘T) and run the same thing in both: the parsing
// benchmark says libghostty is 9-27x faster at consuming bytes (see
// spike/libghostty/FINDINGS.md), and this is where you find out whether that
// is visible to a person or only to a stopwatch.
//
// It is deliberately the LOCAL shell and not SSH. A local PTY has no network
// throttling the output, which is the only place the parsing gap can show; and
// wiring it here keeps the SSH stack untouched, so nothing that already works
// is put at risk by an experiment.
//
// WHAT IT DOES NOT DO YET, on purpose — everything below hangs off SwiftTerm's
// view in this app and would each need re-plumbing: session logging, ⌘F search,
// broadcast input, ZMODEM, the six colour themes, and the dead-shell
// Return/Esc handling. Those are the real cost of a full swap, and leaving them
// out is what makes this a spike rather than a half-migration.

import AppKit
import Combine
import Foundation
import GhosttyTerminal
import MacMobaCore
import SwiftTerm
import SwiftUI

@MainActor
final class GhosttyTerminalTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()

    @Published var title = "libghostty"
    @Published var state: TerminalTab.State = .connecting

    /// GhosttyTerminal and SwiftTerm both export a `TerminalView`, so this one
    /// has to say which it means every time it is named.
    let termView: GhosttyTerminal.TerminalView

    private var process: LocalProcess?
    private var session: InMemoryTerminalSession?
    /// Last size libghostty reported, answered back when the PTY asks. The
    /// terminal is the authority on the grid here: it owns the font metrics,
    /// so it is the only thing that knows how many columns actually fit.
    private var viewport = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

    private let controller = TerminalController { builder in
        builder.withBackgroundOpacity(1)
    }

    override init() {
        termView = GhosttyTerminal.TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()

        let session = InMemoryTerminalSession(
            // Bytes the terminal produces — keystrokes, paste, replies to
            // device queries — go to the shell.
            write: { [weak self] data in
                MainActor.assumeIsolated {
                    guard let self, let process = self.process else { return }
                    process.send(data: ArraySlice(data))
                }
            },
            // libghostty measured a new grid. Remember it, and tell the PTY,
            // or the shell keeps line-wrapping to the old width.
            resize: { [weak self] port in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.viewport = winsize(
                        ws_row: port.rows,
                        ws_col: port.columns,
                        ws_xpixel: UInt16(truncatingIfNeeded: port.widthPixels),
                        ws_ypixel: UInt16(truncatingIfNeeded: port.heightPixels))
                    self.applyWindowSize()
                }
            },
            // This host repaints on every dispatch and reads only rows and
            // columns, which is exactly the case the flag is meant for: a
            // divider drag is mostly sub-cell movement, and each one would
            // otherwise ask the shell to re-wrap for no change.
            suppressesPixelOnlyResizes: true
        )
        self.session = session

        termView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        termView.controller = controller
        termView.delegate = self
    }

    func start(directory: String? = nil) {
        guard process == nil else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = (shell as NSString).lastPathComponent
        // xterm-256color, not xterm-ghostty: the package ships a terminfo for
        // the latter but it is not installed on this Mac, and a TERM the shell
        // cannot look up breaks clear, colours and editors. The comparison
        // stays fair anyway, because the SwiftTerm pane advertises the same.
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")

        let process = LocalProcess(delegate: self)
        self.process = process
        state = .connected
        process.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: "-\(name)",
            currentDirectory: directory ?? FileManager.default.homeDirectoryForCurrentUser.path)
        applyWindowSize()
    }

    func disconnect() {
        process?.terminate()
        process = nil
        state = .closed("shell exited")
    }

    /// LocalProcess only reads the window size when it starts the child, so a
    /// later resize has to reach the PTY directly. `childfd` is public for
    /// exactly this.
    private func applyWindowSize() {
        guard let process, process.childfd >= 0 else { return }
        var size = viewport
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }
}

// MARK: - the shell

extension GhosttyTerminalTab: LocalProcessDelegate {
    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated {
            state = .closed(exitCode.map { "shell exited (\($0))" } ?? "shell exited")
            title = "libghostty — exited"
        }
    }

    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        let data = Data(slice)
        MainActor.assumeIsolated {
            session?.receive(data)
        }
    }

    nonisolated func getWindowSize() -> winsize {
        MainActor.assumeIsolated { viewport }
    }
}

// MARK: - the surface

extension GhosttyTerminalTab: TerminalSurfaceTitleDelegate,
                              TerminalSurfaceResizeDelegate,
                              TerminalSurfaceCloseDelegate {
    nonisolated func terminalDidChangeTitle(_ title: String) {
        MainActor.assumeIsolated {
            // Kept marked, because the whole point of the pane is telling it
            // apart from the SwiftTerm one sitting next to it.
            self.title = title.isEmpty ? "libghostty" : "👻 \(title)"
        }
    }

    nonisolated func terminalDidResize(columns: Int, rows: Int) {}

    nonisolated func terminalDidClose(processAlive: Bool) {
        MainActor.assumeIsolated { disconnect() }
    }
}

/// Hosts the libghostty surface in SwiftUI.
///
/// Uses its own container rather than `PaneContainerView`, which is typed to
/// SwiftTerm's `TerminalView`. The re-parenting problem is the same one though
/// — a bare AppKit view lives wherever the last host put it — so `adopt()` is
/// idempotent and runs on every update, exactly as the SwiftTerm panes do.
struct GhosttyTerminalHostView: NSViewRepresentable {
    let tab: GhosttyTerminalTab
    var onFocus: () -> Void = {}

    final class Container: NSView {
        let termView: GhosttyTerminal.TerminalView
        var onFocusGained: (() -> Void)?

        init(termView: GhosttyTerminal.TerminalView) {
            self.termView = termView
            super.init(frame: .zero)
            adopt()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func adopt() {
            guard termView.superview !== self else { return }
            termView.removeFromSuperview()
            termView.frame = bounds
            termView.autoresizingMask = [.width, .height]
            addSubview(termView)
        }

        override func layout() {
            super.layout()
            termView.frame = bounds
            // libghostty measures the grid from the view's own size, so it has
            // to be told the layout changed; without this the shell keeps the
            // columns it started with and wraps in the wrong place.
            termView.fitToSize()
        }
    }

    func makeNSView(context: Context) -> Container {
        let container = Container(termView: tab.termView)
        container.onFocusGained = onFocus
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(container.termView)
            onFocus()
        }
        return container
    }

    func updateNSView(_ nsView: Container, context: Context) {
        nsView.adopt()
    }
}

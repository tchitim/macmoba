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

/// The PTY side, deliberately off the main actor.
///
/// libghostty runs terminal IO on its own thread and calls the session's write
/// and resize hooks from there; LocalProcess delivers PTY output on a dispatch
/// queue. An earlier version of this file answered both with
/// `MainActor.assumeIsolated`, which is an assertion rather than a hop — so the
/// first time a surface actually got built, the resize callback arrived on
/// `Termio.threadEnter` and aborted the process. Everything those callbacks
/// touch therefore lives here, where nothing pretends to be main-actor.
private final class PTYBridge: NSObject, LocalProcessDelegate, @unchecked Sendable {
    /// Set once, immediately after construction and before any shell starts.
    var session: InMemoryTerminalSession?
    var onExit: ((Int32?) -> Void)?

    /// The grid libghostty last measured. Written from its IO thread, read
    /// from LocalProcess's queue when it starts the child, hence the lock.
    private let sizeLock = NSLock()
    private var viewport = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

    func setViewport(_ size: winsize) {
        sizeLock.lock()
        viewport = size
        sizeLock.unlock()
    }

    func getWindowSize() -> winsize {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return viewport
    }

    /// Handed to the session as-is. InMemoryTerminalSession is Sendable and
    /// does its own thread handling, and bouncing every chunk of PTY output
    /// through the main queue would serialise the very path this pane exists
    /// to measure.
    func dataReceived(slice: ArraySlice<UInt8>) {
        session?.receive(Data(slice))
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onExit?(exitCode)
    }
}

@MainActor
final class GhosttyTerminalTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()

    @Published var state: TerminalTab.State = .connecting

    /// The package's own view state. Hand-rolling an NSViewRepresentable
    /// around its TerminalView looked fine and quietly did not work: the
    /// surface is built from `viewDidMoveToWindow` via `rebuildIfReady`, and
    /// driving that is the view layer's job, not this file's.
    let surfaceState = TerminalViewState()

    private let bridge = PTYBridge()
    private let process: LocalProcess
    private let session: InMemoryTerminalSession
    private var started = false

    override init() {
        let bridge = self.bridge
        let process = LocalProcess(delegate: bridge)
        self.process = process

        session = InMemoryTerminalSession(
            // Bytes the terminal produces — keystrokes, paste, replies to
            // device queries — go straight to the shell. LocalProcess.send
            // hands off to DispatchIO, so it needs no hop of its own.
            write: { data in
                process.send(data: ArraySlice(data))
            },
            // libghostty measured a new grid. Tell the PTY, or the shell keeps
            // wrapping at the width it started with.
            resize: { port in
                var size = winsize(
                    ws_row: port.rows,
                    ws_col: port.columns,
                    ws_xpixel: UInt16(truncatingIfNeeded: port.widthPixels),
                    ws_ypixel: UInt16(truncatingIfNeeded: port.heightPixels))
                bridge.setViewport(size)
                // LocalProcess only reads the window size when it starts the
                // child, so a later resize has to reach the PTY directly.
                // ioctl is safe from any thread; childfd is public for this.
                if process.childfd >= 0 {
                    _ = ioctl(process.childfd, TIOCSWINSZ, &size)
                }
            },
            // This host repaints on every dispatch and reads only rows and
            // columns, which is the case the flag is for: a divider drag is
            // mostly sub-cell movement, and each one would otherwise ask the
            // shell to re-wrap for no change.
            suppressesPixelOnlyResizes: true
        )

        super.init()

        bridge.session = session
        bridge.onExit = { [weak self] code in
            Task { @MainActor in
                self?.state = .closed(code.map { "shell exited (\($0))" } ?? "shell exited")
            }
        }
        surfaceState.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        surfaceState.onClose = { [weak self] _ in
            Task { @MainActor in self?.disconnect() }
        }
    }

    /// Started from the view's `onAppear`, not from here: the surface is built
    /// when the view reaches a window, and a shell started before that has
    /// nowhere to put its first output.
    func start(directory: String? = nil) {
        guard !started else { return }
        started = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = (shell as NSString).lastPathComponent
        // xterm-256color, not xterm-ghostty: the package ships a terminfo for
        // the latter but it is not installed on this Mac, and a TERM the shell
        // cannot look up breaks clear, colours and editors. The comparison
        // stays fair anyway, because the SwiftTerm pane advertises the same.
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")

        state = .connected
        process.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: "-\(name)",
            currentDirectory: directory ?? FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func disconnect() {
        process.terminate()
        state = .closed("shell exited")
    }

    /// Title tracking rides on TerminalViewState, which republishes it, so
    /// this reads through rather than keeping a second copy that can drift.
    /// Marked, because telling this pane apart from the SwiftTerm one beside
    /// it is the whole point.
    var displayTitle: String {
        surfaceState.title.isEmpty ? "libghostty" : "👻 \(surfaceState.title)"
    }
}

/// The pane, drawn by the package's own SwiftUI surface view.
struct GhosttyTerminalPaneView: View {
    @ObservedObject var tab: GhosttyTerminalTab

    var body: some View {
        TerminalSurfaceView(context: tab.surfaceState)
            .onAppear {
                tab.start()
                tab.surfaceState.requestFocus()
            }
    }
}

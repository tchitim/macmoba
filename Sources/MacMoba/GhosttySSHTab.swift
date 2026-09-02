// EXPERIMENTAL: an SSH session drawn by libghostty instead of SwiftTerm.
//
// The sibling of GhosttyTerminalTab, and simpler than it: InMemoryTerminalSession
// never knew about a PTY, and TerminalTransport is already write/resize/close,
// so there is no LocalProcess and no TIOCSWINSZ here — a resize is an SSH
// window-change like any other.
//
// WORTH KNOWING BEFORE READING THE NUMBERS. Measured end to end on a local
// shell, libghostty is 2.95x faster than SwiftTerm (0.205s vs 0.604s for 14MB
// of CJK), and that gap exists only because a local PTY has nothing throttling
// it. Over SSH the network joins the queue: SwiftTerm already moves 23 MB/s and
// libghostty 68 MB/s, so unless the link delivers faster than 23 MB/s the
// terminal is not the limit and this changes nothing. That is the question this
// pane exists to answer, and the answer may well be "no difference".
//
// WHAT IT DOES NOT DO, and here that list is the point rather than a footnote:
// no session logging, no ⌘F, no broadcast/MultiExec, no ZMODEM, no themes, no
// status bar, no on-connect commands, no bell/attention, no SFTP coupling, no
// read-screen. All of those live on the SwiftTerm pane. A real switch means
// rebuilding every one of them, which is the difference between this spike and
// the weeks a migration would cost.

import AppKit
import Combine
import Foundation
import GhosttyTerminal
import MacMobaCore
import SwiftUI

@MainActor
final class GhosttySSHTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let config: SessionConfig

    @Published var state: TerminalTab.State = .connecting
    let surfaceState = TerminalViewState()

    private weak var app: AppState?
    private let session: InMemoryTerminalSession

    /// Written from libghostty's IO thread and read when the connection is
    /// dialled, so both sides take the lock.
    private let stateLock = NSLock()
    private nonisolated(unsafe) var transport: (any TerminalTransport)?
    private nonisolated(unsafe) var grid = (cols: 80, rows: 24)
    private var connecting = false

    init(config: SessionConfig, app: AppState?) {
        self.config = config
        self.app = app

        // Deliberately no main-actor assumptions: libghostty calls write and
        // resize from its own terminal IO thread, and SSHConnection's data
        // arrives on a NIO event loop. TerminalTransport is Sendable, which is
        // what makes serving them directly safe.
        let lock = stateLock
        var transportRef: (() -> (any TerminalTransport)?)!

        session = InMemoryTerminalSession(
            write: { data in
                lock.lock(); let t = transportRef(); lock.unlock()
                t?.write(data)
            },
            resize: { port in
                lock.lock(); let t = transportRef(); lock.unlock()
                t?.resize(cols: Int(port.columns), rows: Int(port.rows))
            },
            suppressesPixelOnlyResizes: true
        )

        super.init()
        transportRef = { [weak self] in self?.transport }
        surfaceState.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        surfaceState.onClose = { [weak self] _ in
            Task { @MainActor in self?.disconnect() }
        }
    }

    /// Records the grid libghostty measured, so the connection can be opened at
    /// the right size rather than at 80x24 and immediately resized.
    private func currentGrid() -> (cols: Int, rows: Int) {
        if let metrics = surfaceState.surfaceSize {
            let cols = Int(metrics.columns), rows = Int(metrics.rows)
            if cols > 0, rows > 0 { return (cols, rows) }
        }
        return grid
    }

    func connect() {
        guard !connecting, transport == nil else { return }
        connecting = true
        state = .connecting
        let size = currentGrid()
        Task {
            do {
                let resolved = try await SecretResolver.resolve(session: config)
                var chain: [SessionConfig] = []
                if let app { chain = await app.jumpChain(for: config) }
                let jumps = try await SecretResolver.resolve(sessions: chain)
                let hostKeys = app?.hostKeyVerification
                let made = try await SSHConnection.connect(
                    config: resolved,
                    cols: size.cols,
                    rows: size.rows,
                    hostKeys: hostKeys,
                    jumps: jumps,
                    // Straight into the terminal from the event loop. The
                    // session is Sendable and does its own thread handling, and
                    // hopping every chunk to the main queue would throttle the
                    // exact path this pane is here to measure.
                    onData: { [weak self] data in self?.session.receive(data) },
                    onExit: { [weak self] reason in
                        Task { @MainActor in self?.handleExit(reason) }
                    }
                )
                await MainActor.run {
                    self.stateLock.lock()
                    self.transport = made
                    self.stateLock.unlock()
                    // The surface may have been measured while the connection
                    // was being dialled.
                    let now = self.currentGrid()
                    made.resize(cols: now.cols, rows: now.rows)
                    self.state = .connected
                    self.connecting = false
                }
            } catch {
                await MainActor.run {
                    self.state = .closed("\(error)")
                    self.connecting = false
                }
            }
        }
    }

    private func handleExit(_ reason: String?) {
        stateLock.lock(); transport = nil; stateLock.unlock()
        state = .closed(reason ?? "disconnected")
    }

    func disconnect() {
        stateLock.lock()
        let t = transport
        transport = nil
        stateLock.unlock()
        t?.close()
        state = .closed("disconnected")
    }

    var displayTitle: String {
        let name = surfaceState.title.isEmpty ? config.name : surfaceState.title
        return "👻 \(name)"
    }
}

/// The pane, drawn by the package's own SwiftUI surface view.
struct GhosttySSHPaneView: View {
    @ObservedObject var tab: GhosttySSHTab

    var body: some View {
        ZStack {
            TerminalSurfaceView(context: tab.surfaceState)
            if case .closed(let why) = tab.state {
                // No status bar on this pane, so a failed connection would
                // otherwise be an empty black rectangle with no explanation.
                Text(why)
                    .font(.callout)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear {
            tab.connect()
            tab.surfaceState.requestFocus()
        }
    }
}

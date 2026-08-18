// Mosh as a terminal transport.
//
// The mosh C++ core is shipped as its own binary and run as a child process on
// a PTY, rather than linked in. That is deliberate:
//
//  * mosh has no library API — the upstream project builds programs, and its
//    state-synchronisation and AES-OCB crypto are not exposed as anything
//    stable to call into.
//  * Re-implementing SSP in Swift would mean a fresh implementation of a
//    security protocol with none of the review the original has had.
//  * mosh is GPLv3. Kept as a separate executable talking over a pipe, it stays
//    a separate program rather than being linked into this one.
//
// Bytes go: SwiftTerm -> LocalProcess (PTY) -> mosh-client -> UDP -> server.

import Foundation
import MacMobaCore
import SwiftTerm

/// Runs the bundled mosh-client and presents it as something a pane can drive.
final class MoshTransport: NSObject, TerminalTransport, @unchecked Sendable {
    private let process: LocalProcess
    /// Held strongly on purpose: `LocalProcess.delegate` is `weak`, so nothing
    /// else keeps this alive. Letting it go produced a running mosh-client
    /// whose output never arrived — the process was there, the callbacks were
    /// not. There is no cycle to avoid: the delegate points back weakly.
    private let delegate: Delegate
    private let onData: (Data) -> Void
    private let onExit: (String) -> Void
    /// Guarded because the size is read from LocalProcess's own thread.
    private let sizeLock = NSLock()
    private var cols: Int
    private var rows: Int
    private var terminated = false

    /// Where the vendored client lives inside the app bundle.
    static var clientURL: URL? {
        // Resources rather than MacOS: it is a helper, not the app's own
        // executable, and Contents/MacOS is expected to hold one binary.
        if let bundled = Bundle.main.url(forResource: "mosh-client", withExtension: nil) {
            return bundled
        }
        // Running from a plain `swift build` during development.
        let vendored = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/Mosh/bin/mosh-client")
        return FileManager.default.isExecutableFile(atPath: vendored.path) ? vendored : nil
    }

    init(session: MoshSession, host: String, cols: Int, rows: Int,
         onData: @escaping (Data) -> Void,
         onExit: @escaping (String) -> Void) throws {
        guard let client = Self.clientURL else { throw MoshTransportError.clientMissing }
        self.cols = cols
        self.rows = rows
        self.onData = onData
        self.onExit = onExit
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("LANG=en_US.UTF-8")
        // The key goes in the environment, never in argv: argv is visible to
        // every process on this Mac through `ps`, and this key is the entire
        // security of the session. mosh-client unsets it as soon as it starts.
        environment.append("MOSH_KEY=\(session.key)")

        let delegate = Delegate()
        self.delegate = delegate
        self.process = LocalProcess(delegate: delegate)
        super.init()
        delegate.owner = self

        process.startProcess(
            executable: client.path,
            args: [host, String(session.port)],
            environment: environment
        )
    }

    func write(_ data: Data) {
        process.send(data: ArraySlice([UInt8](data)))
    }

    func resize(cols: Int, rows: Int) {
        sizeLock.lock()
        self.cols = cols
        self.rows = rows
        sizeLock.unlock()
        // LocalProcess only asks for the size when it starts the process, so a
        // later resize has to be pushed onto the PTY here. That is what raises
        // SIGWINCH in mosh-client, which then re-syncs the remote size.
        // SwiftTerm exposes this because Swift cannot call variadic ioctl.
        var size = currentWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd,
                                             windowSize: &size)
    }

    func close() {
        guard !terminated else { return }
        terminated = true
        process.terminate()
    }

    fileprivate func currentWindowSize() -> winsize {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return winsize(ws_row: UInt16(rows), ws_col: UInt16(cols),
                       ws_xpixel: 0, ws_ypixel: 0)
    }

    fileprivate func handleData(_ slice: ArraySlice<UInt8>) {
        onData(Data(slice))
    }

    fileprivate func handleExit(_ code: Int32?) {
        guard !terminated else { return }
        terminated = true
        // mosh-client exits 0 when the user leaves the session normally.
        onExit(code.map { $0 == 0 ? "Session ended." : "mosh-client exited with status \($0)." }
               ?? "Session ended.")
    }

    /// Separate object rather than conforming `MoshTransport` itself, so the
    /// delegate methods stay off the transport's public surface. Owned by the
    /// transport (see `delegate` above) because LocalProcess will not keep it.
    private final class Delegate: LocalProcessDelegate {
        weak var owner: MoshTransport?

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            owner?.handleExit(exitCode)
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            owner?.handleData(slice)
        }

        func getWindowSize() -> winsize {
            owner?.currentWindowSize() ?? winsize(ws_row: 24, ws_col: 80,
                                                  ws_xpixel: 0, ws_ypixel: 0)
        }
    }
}

enum MoshTransportError: Error, LocalizedError {
    case clientMissing

    var errorDescription: String? {
        switch self {
        case .clientMissing:
            return "The bundled mosh-client is missing from this build "
                 + "(run scripts/build-mosh.sh)."
        }
    }
}

// Fetching a password from a manager at connect time.
//
// SecretReference (in Core) decides what to run; this runs it. A reference like
// `op://…` or `cmd:…` becomes a short-lived subprocess whose output is the
// secret, so the vault never holds the password itself. The fetched value is
// used to build the SSH/VNC/RDP login and then dropped — it is not cached.

import Foundation

public enum SecretResolver {
    public enum ResolveError: LocalizedError {
        case failed(command: String, status: Int32, message: String)
        case launchFailed(String)
        case timedOut(command: String, seconds: Int)

        public var errorDescription: String? {
            switch self {
            case .failed(let command, let status, let message):
                let detail = message.isEmpty ? "" : " — \(message)"
                return "Fetching the password with “\(command)” failed "
                    + "(exit \(status))\(detail)"
            case .launchFailed(let m):
                return "Could not run the password command: \(m)"
            case .timedOut(let command, let seconds):
                return "“\(command)” gave no answer in \(seconds)s. If this is "
                    + "1Password, look for its authorization prompt — it may be "
                    + "on another Space — and check Settings → Developer → "
                    + "“Integrate with 1Password CLI”."
            }
        }
    }

    /// The literal password behind `raw`: run the manager if it is a reference,
    /// otherwise hand it straight back. 1Password may prompt for Touch ID, so
    /// this can take a while; it runs off the main thread. The timeout turns a
    /// manager stuck waiting for input into an error instead of a connection
    /// that hangs forever.
    public static func resolve(_ raw: String, timeout: TimeInterval = 60) async throws -> String {
        guard let argv = SecretReference.parse(raw).fetchArgv() else { return raw }
        return try await run(argv, timeout: timeout)
    }

    /// A copy of `session` with its password and passphrase resolved, so the
    /// connection code sees literal secrets and knows nothing about managers.
    public static func resolve(session: SessionConfig) async throws -> SessionConfig {
        var s = session
        if let pw = s.password, SecretReference.parse(pw).isReference {
            s.password = try await resolve(pw)
        }
        if let pp = s.passphrase, SecretReference.parse(pp).isReference {
            s.passphrase = try await resolve(pp)
        }
        return s
    }

    /// Resolve each session in a jump chain.
    public static func resolve(sessions: [SessionConfig]) async throws -> [SessionConfig] {
        var out: [SessionConfig] = []
        out.reserveCapacity(sessions.count)
        for s in sessions { out.append(try await resolve(session: s)) }
        return out
    }

    private static func run(_ argv: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: argv[0])
                process.arguments = Array(argv.dropFirst())
                // env needs a PATH that includes where op/security/pass usually
                // live; a GUI app inherits a minimal one otherwise.
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                process.environment = environment

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                // No terminal here: a tool that would prompt on stdin must see
                // EOF and fail fast, not sit waiting for typing that can never
                // arrive.
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ResolveError.launchFailed(
                        error.localizedDescription))
                    return
                }
                // The watchdog: a manager stuck past the deadline (waiting for
                // an authorization no one can see) is killed, which unblocks
                // the reads below and surfaces as a clear error.
                let timedOut = LockedFlag()
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.set()
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout,
                                                  execute: watchdog)

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                if timedOut.isSet {
                    continuation.resume(throwing: ResolveError.timedOut(
                        command: argv.joined(separator: " "),
                        seconds: Int(timeout)))
                    return
                }
                if process.terminationStatus != 0 {
                    let message = String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ResolveError.failed(
                        command: argv.joined(separator: " "),
                        status: process.terminationStatus, message: message))
                    return
                }
                // A password is whatever came out, minus a single trailing
                // newline the tool likely added; inner whitespace is kept.
                var secret = String(decoding: outData, as: UTF8.self)
                if secret.hasSuffix("\n") { secret.removeLast() }
                if secret.hasSuffix("\r") { secret.removeLast() }
                continuation.resume(returning: secret)
            }
        }
    }
}

/// A set-once flag shared between the watchdog and the reader thread.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

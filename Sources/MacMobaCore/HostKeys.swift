// Host key verification: OpenSSH-style SHA256 fingerprints, pinned per
// host:port. Unknown or changed keys are decided by a prompt callback
// (the app shows UI; tests inject a closure).

import Crypto
import Foundation
import NIOCore
import NIOSSH

/// Persists trusted fingerprints. Implementations must be thread-safe:
/// lookups happen on the SSH event loop.
public protocol HostKeyStore: AnyObject, Sendable {
    func storedFingerprint(host: String, port: Int) -> String?
    func store(fingerprint: String, host: String, port: Int)
}

/// Called for an unknown key (storedFingerprint == nil) or a MISMATCH
/// (storedFingerprint != nil). Call `decision(true)` to trust and continue.
/// May be invoked on any thread.
public typealias HostKeyPrompt = @Sendable (
    _ host: String,
    _ port: Int,
    _ fingerprint: String,
    _ keyType: String,
    _ storedFingerprint: String?,
    _ decision: @escaping @Sendable (Bool) -> Void
) -> Void

public struct HostKeyVerification: Sendable {
    public let store: HostKeyStore
    public let prompt: HostKeyPrompt

    public init(store: HostKeyStore, prompt: @escaping HostKeyPrompt) {
        self.store = store
        self.prompt = prompt
    }
}

/// Bridges "user rejected the host key" to the transport: NIOSSH does not tear
/// the connection down on a failed host-key check, so without this the connect
/// would sit until the timeout instead of failing at once.
final class HostKeyRejection: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false
    private var handler: (() -> Void)?

    var wasRejected: Bool {
        lock.lock(); defer { lock.unlock() }
        return rejected
    }

    func reject() {
        lock.lock()
        rejected = true
        let handler = self.handler
        lock.unlock()
        handler?()
    }

    func onReject(_ handler: @escaping () -> Void) {
        lock.lock()
        let already = rejected
        self.handler = handler
        lock.unlock()
        if already { handler() }
    }
}

public enum HostKeyFingerprint {
    /// OpenSSH-style fingerprint ("SHA256:...") + key type ("ssh-ed25519").
    public static func compute(for key: NIOSSHPublicKey) -> (fingerprint: String, keyType: String) {
        let openSSH = String(openSSHPublicKey: key)
        let parts = openSSH.split(separator: " ")
        let keyType = parts.first.map(String.init) ?? "unknown"
        let blob = parts.count > 1 ? (Data(base64Encoded: String(parts[1])) ?? Data()) : Data()
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return ("SHA256:" + b64, keyType)
    }
}

final class VerifyingHostKeys: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: Int
    private let verification: HostKeyVerification
    private let rejection: HostKeyRejection

    init(host: String, port: Int, verification: HostKeyVerification, rejection: HostKeyRejection) {
        self.host = host
        self.port = port
        self.verification = verification
        self.rejection = rejection
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let (fingerprint, keyType) = HostKeyFingerprint.compute(for: hostKey)
        let stored = verification.store.storedFingerprint(host: host, port: port)
        if stored == fingerprint {
            validationCompletePromise.succeed(())
            return
        }
        let verification = self.verification
        let host = self.host
        let port = self.port
        let rejection = self.rejection
        verification.prompt(host, port, fingerprint, keyType, stored) { trusted in
            if trusted {
                verification.store.store(fingerprint: fingerprint, host: host, port: port)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(
                    SSHError.hostKeyRejected("\(host):\(port) (\(fingerprint))"))
                // Tear the transport down so the caller fails now, not at timeout.
                rejection.reject()
            }
        }
    }
}

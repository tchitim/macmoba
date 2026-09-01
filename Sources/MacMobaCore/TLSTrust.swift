// TLS certificate identity for the web tab.
//
// Internal consoles — OpenShift, Cockpit, a switch's admin UI, anything behind
// a lab CA — are overwhelmingly self-signed, and WebKit refuses them outright
// with no way through. The answer is not "ignore TLS errors": that would turn
// every one of these tabs into an unauthenticated channel forever. It is the
// same bargain the SSH host key and the RDP certificate already make here —
// show the fingerprint once, pin it, and refuse quietly ever after if it
// changes.

import Crypto
import Foundation

public enum TLSFingerprint {
    /// Colon-separated uppercase hex of the SHA-256 over the certificate's DER
    /// bytes. That is deliberately the shape `openssl x509 -fingerprint
    /// -sha256` prints and Keychain Access displays, because the only reason to
    /// show a user a fingerprint is so they can compare it with one from the
    /// server — a format they have to convert first is a format they will skip.
    public static func sha256(der: Data) -> String {
        SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

public enum WebCertificateTrust {
    public enum Outcome: Equatable {
        /// Pinned earlier and unchanged — proceed without interrupting anyone.
        case trusted
        /// Never seen this server. Normal for a self-signed console.
        case askFirstTime
        /// Pinned earlier and the fingerprint is different now. Could be a
        /// rebuild; could be someone in the middle. Never auto-answered.
        case askChanged(from: String)
    }

    public static func outcome(stored: String?, offered: String) -> Outcome {
        guard let stored else { return .askFirstTime }
        // Fingerprints are hex, so case is meaningless and a store written by
        // an older build must not read as a mismatch — which would show the
        // alarming "changed" alert for a certificate that did not change.
        return stored.caseInsensitiveCompare(offered) == .orderedSame
            ? .trusted
            : .askChanged(from: stored)
    }
}

// Pinned certificates for web tabs, and the prompt that pins them.
//
// A fourth store rather than a shared one, for the reason the RDP store gives:
// these identities look alike and mixing them invites a lookup that matches the
// wrong sort.

import AppKit
import Foundation
import MacMobaCore
import Security

enum WebCertificateStore {
    static let shared = KnownHostsStore(
        fileURL: AppState.dataDirectory.appendingPathComponent("web_certs.json"))
}

enum WebCertificate {
    /// The leaf certificate's fingerprint and common name, or nil when the
    /// chain is empty — which should not happen for a TLS challenge, but an
    /// empty chain must fail closed rather than being pinned as "".
    static func identity(of trust: SecTrust) -> (fingerprint: String, commonName: String)? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        var name: CFString?
        SecCertificateCopyCommonName(leaf, &name)
        return (TLSFingerprint.sha256(der: der), (name as String?) ?? "unnamed")
    }

    /// Whether macOS is already happy with this chain. Asked first so that a
    /// properly signed site never produces a prompt: this whole path exists for
    /// certificates the system rejects, and prompting for good ones would train
    /// people to click through the bad ones.
    static func isSystemTrusted(_ trust: SecTrust) -> Bool {
        SecTrustEvaluateWithError(trust, nil)
    }
}

@MainActor
enum WebCertificatePrompt {
    static func ask(host: String, commonName: String, fingerprint: String,
                    reason: WebCertificateTrust.Outcome) -> Bool {
        let alert = NSAlert()
        var details = "Common name: \(commonName)\nSHA-256: \(fingerprint)"

        switch reason {
        case .trusted:
            return true
        case .askFirstTime:
            alert.alertStyle = .warning
            alert.messageText = "Trust the certificate for \(host)?"
            alert.informativeText =
                "This server's certificate is not signed by an authority your Mac trusts. "
                + "That is normal for an internal console with a self-signed or private-CA "
                + "certificate — and it is also what an impostor looks like, so check the "
                + "fingerprint against the server before trusting it. "
                + "It will be remembered for this host."
        case .askChanged(let previous):
            alert.alertStyle = .critical
            alert.messageText = "The certificate for \(host) has changed."
            alert.informativeText =
                "You trusted a different certificate for this server before. That can mean "
                + "the server was rebuilt — or that something is impersonating it."
            details += "\nPreviously: \(previous)"
        }

        alert.informativeText += "\n\n" + details
        alert.addButton(withTitle: "Trust and Continue")
        alert.addButton(withTitle: "Cancel")
        if case .askChanged = reason { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }
}

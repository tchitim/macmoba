// App-side host key handling: JSON known-hosts store + NSAlert trust prompt.
// Concurrent connections to the same new host (terminal + SFTP) share one
// prompt instead of stacking alerts.

import AppKit
import Foundation
import MacMobaCore

/// Pinned RDP server certificates, in the same shape and directory as
/// known_hosts.json but a separate file: these are TLS certificate fingerprints,
/// not SSH host keys, and keeping two kinds of secret-adjacent identity in one
/// map only invites a lookup that matches the wrong sort.
///
/// This exists because the FreeRDP shim answers "accept once" so that FreeRDP
/// never writes its own known_hosts — which left the accepted certificate
/// remembered precisely nowhere, and re-prompted on every connect.
enum RDPCertificateStore {
    static let shared = KnownHostsStore(
        fileURL: AppState.dataDirectory.appendingPathComponent("rdp_certs.json"))
}

/// Serializes trust prompts: while a decision for host:port is pending, other
/// callers for the same key wait for that one answer.
@MainActor
final class HostKeyPrompter {
    private var pending: [String: [(Bool) -> Void]] = [:]
    private let store: HostKeyStore
    /// "Trust the other new hosts too", ticked once when a folder of machines
    /// is opened. Only ever covers first-time keys — see TrustBurstPolicy.
    private var burst = TrustBurstPolicy()
    /// The checkbox of the alert currently on screen, read once it closes.
    private var burstCheckbox: NSButton?

    init(store: HostKeyStore) {
        self.store = store
    }

    func ask(host: String, port: Int, fingerprint: String, keyType: String,
             stored: String?, decision: @escaping (Bool) -> Void) {
        let key = "\(host):\(port)|\(fingerprint)"
        // Someone may have trusted this exact key while we were queued behind
        // their modal — NSAlert.runModal blocks this actor, so concurrent
        // connections arrive here one after another rather than together.
        // Without this check the user gets one dialog per connection.
        if store.storedFingerprint(host: host, port: port) == fingerprint {
            decision(true)
            return
        }
        // A burst the user opened a moment ago answers for first-time keys.
        // `stored != nil` means the key CHANGED, which the policy refuses to
        // cover no matter what — that prompt always reaches the user.
        if burst.allowsAutoTrust(isChangedKey: stored != nil) {
            decision(true)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(decision)
            return
        }
        pending[key] = [decision]

        let alert = NSAlert()
        if let stored {
            alert.alertStyle = .critical
            alert.messageText = "Host key for \(host) has CHANGED"
            alert.informativeText = """
            The server's \(keyType) key does not match the one you trusted before. \
            This can mean a man-in-the-middle attack, or that the server was reinstalled.

            Stored:  \(stored)
            Offered: \(fingerprint)

            Only continue if you know why the key changed.
            """
            alert.addButton(withTitle: "Disconnect")
            alert.addButton(withTitle: "Trust New Key")
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Connect to \(host)?"
            alert.informativeText = """
            The authenticity of \(host):\(port) can't be established yet.

            \(keyType) key fingerprint:
            \(fingerprint)

            Compare it with the server's (ssh-keygen -lf /etc/ssh/ssh_host_*.pub). \
            If you trust it, the key is pinned for future connections.
            """
            alert.addButton(withTitle: "Trust and Connect")
            alert.addButton(withTitle: "Cancel")
            // Opening a folder means one of these per machine. Ticking this
            // makes the same first-time decision for the rest of the batch;
            // a CHANGED key still stops and asks.
            let trustRest = NSButton(checkboxWithTitle:
                "Also trust other new hosts for the next 2 minutes", target: nil, action: nil)
            trustRest.sizeToFit()
            alert.accessoryView = trustRest
            burstCheckbox = trustRest
        }

        let response = alert.runModal()
        // Mismatch alert puts the safe choice first, so "trust" is the 2nd button.
        let trusted = stored == nil
            ? response == .alertFirstButtonReturn
            : response == .alertSecondButtonReturn
        // Only a first-time key can open a burst, and only when trusted.
        if trusted, stored == nil, burstCheckbox?.state == .on {
            burst.open()
        }
        burstCheckbox = nil
        let waiters = pending.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter(trusted) }
    }
}

extension AppState {
    /// Build the verification hook handed to every core connect call.
    static func makeHostKeyVerification(store: KnownHostsStore,
                                        prompter: HostKeyPrompter) -> HostKeyVerification {
        HostKeyVerification(store: store) { host, port, fingerprint, keyType, stored, decision in
            Task { @MainActor in
                prompter.ask(host: host, port: port, fingerprint: fingerprint,
                             keyType: keyType, stored: stored) { trusted in
                    decision(trusted)
                }
            }
        }
    }
}

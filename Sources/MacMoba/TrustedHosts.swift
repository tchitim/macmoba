// Reviewing and revoking pinned server identities.
//
// Three stores feed this: SSH host keys (known_hosts.json), RDP server
// certificates (rdp_certs.json) and web-tab certificates (web_certs.json).
// All three are "I decided to trust this once", and the only way to undo one
// otherwise would be to hand-edit JSON.

import MacMobaCore
import SwiftUI

struct TrustedHost: Identifiable {
    enum Kind: String, CaseIterable {
        case ssh
        case rdp
        case tls

        var title: String {
            switch self {
            case .ssh: return "SSH Host Keys"
            case .rdp: return "RDP Server Certificates"
            case .tls: return "Web Certificates"
            }
        }

        var symbolName: String {
            switch self {
            case .ssh: return SessionKind.ssh.symbolName
            case .rdp: return SessionKind.rdp.symbolName
            case .tls: return SessionKind.web.symbolName
            }
        }

        var footnote: String {
            switch self {
            case .ssh:
                return "Pinned the first time you connected. A key that changes "
                     + "afterwards is refused until you confirm it."
            case .rdp:
                // Kept to roughly the length of the SSH note above: a List
                // section footer truncates to one line rather than wrapping,
                // and .fixedSize does not override that.
                return "Self-signed certificates are normal here, so this fingerprint "
                     + "is what identifies the server."
            case .tls:
                return "Trusted by hand because your Mac would not verify them. "
                     + "A certificate that changes afterwards asks again."
            }
        }
    }

    let kind: Kind
    let host: String
    let port: Int
    let fingerprint: String

    var id: String { "\(kind.rawValue)|\(host):\(port)" }
    var address: String { "\(host):\(port)" }
}

@MainActor
final class TrustedHostsModel: ObservableObject {
    @Published private(set) var hosts: [TrustedHost] = []

    private let sshStore: KnownHostsStore
    private let rdpStore: KnownHostsStore
    private let tlsStore: KnownHostsStore

    init(ssh: KnownHostsStore, rdp: KnownHostsStore, tls: KnownHostsStore) {
        self.sshStore = ssh
        self.rdpStore = rdp
        self.tlsStore = tls
        reload()
    }

    func reload() {
        hosts = sshStore.allEntries().map {
            TrustedHost(kind: .ssh, host: $0.host, port: $0.port, fingerprint: $0.fingerprint)
        } + rdpStore.allEntries().map {
            TrustedHost(kind: .rdp, host: $0.host, port: $0.port, fingerprint: $0.fingerprint)
        } + tlsStore.allEntries().map {
            TrustedHost(kind: .tls, host: $0.host, port: $0.port, fingerprint: $0.fingerprint)
        }
    }

    func hosts(of kind: TrustedHost.Kind) -> [TrustedHost] {
        hosts.filter { $0.kind == kind }
    }

    func forget(_ host: TrustedHost) {
        store(for: host.kind).remove(host: host.host, port: host.port)
        reload()
    }

    /// Exhaustive on purpose. As a two-case ternary this silently sent every
    /// new kind to the RDP store, which would "forget" the wrong pin and leave
    /// the real one in place.
    private func store(for kind: TrustedHost.Kind) -> KnownHostsStore {
        switch kind {
        case .ssh: return sshStore
        case .rdp: return rdpStore
        case .tls: return tlsStore
        }
    }
}

struct TrustedHostsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TrustedHostsModel
    /// Confirmed before forgetting: the next connection to that host shows a
    /// trust prompt, and someone who clicks through it out of habit has
    /// undone the pin's whole purpose.
    @State private var pendingForget: TrustedHost?

    init(ssh: KnownHostsStore, rdp: KnownHostsStore, tls: KnownHostsStore) {
        _model = StateObject(wrappedValue: TrustedHostsModel(ssh: ssh, rdp: rdp, tls: tls))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.hosts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(TrustedHost.Kind.allCases, id: \.self) { kind in
                        let hosts = model.hosts(of: kind)
                        if !hosts.isEmpty {
                            Section {
                                ForEach(hosts) { host in
                                    row(host)
                                }
                            } header: {
                                Label(kind.title, systemImage: kind.symbolName)
                            } footer: {
                                Text(kind.footnote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    // Without this a long footnote is truncated
                                    // to one line rather than wrapping.
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("^[\(model.hosts.count) host](inflect: true) trusted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
        .confirmationDialog(
            pendingForget.map { "Forget \($0.address)?" } ?? "",
            isPresented: Binding(get: { pendingForget != nil },
                                 set: { if !$0 { pendingForget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let host = pendingForget { model.forget(host) }
                pendingForget = nil
            }
            Button("Cancel", role: .cancel) { pendingForget = nil }
        } message: {
            Text("The next connection will ask you to trust it again, as if you had "
                 + "never connected. Do this when a server has genuinely been rebuilt.")
        }
    }

    private func row(_ host: TrustedHost) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.address)
                Text(host.fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("Forget") { pendingForget = host }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Nothing trusted yet")
                .font(.headline)
            Text("Server identities appear here once you have confirmed them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// Reviewing and revoking pinned server identities.
//
// Two stores feed this: SSH host keys (known_hosts.json) and RDP server
// certificates (rdp_certs.json). Both are "I decided to trust this once", and
// until now the only way to undo either was to hand-edit JSON.

import MacMobaCore
import SwiftUI

struct TrustedHost: Identifiable {
    enum Kind: String, CaseIterable {
        case ssh
        case rdp

        var title: String {
            switch self {
            case .ssh: return "SSH Host Keys"
            case .rdp: return "RDP Server Certificates"
            }
        }

        var symbolName: String {
            switch self {
            case .ssh: return SessionKind.ssh.symbolName
            case .rdp: return SessionKind.rdp.symbolName
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

    init(ssh: KnownHostsStore, rdp: KnownHostsStore) {
        self.sshStore = ssh
        self.rdpStore = rdp
        reload()
    }

    func reload() {
        hosts = sshStore.allEntries().map {
            TrustedHost(kind: .ssh, host: $0.host, port: $0.port, fingerprint: $0.fingerprint)
        } + rdpStore.allEntries().map {
            TrustedHost(kind: .rdp, host: $0.host, port: $0.port, fingerprint: $0.fingerprint)
        }
    }

    func hosts(of kind: TrustedHost.Kind) -> [TrustedHost] {
        hosts.filter { $0.kind == kind }
    }

    func forget(_ host: TrustedHost) {
        store(for: host.kind).remove(host: host.host, port: host.port)
        reload()
    }

    private func store(for kind: TrustedHost.Kind) -> KnownHostsStore {
        kind == .ssh ? sshStore : rdpStore
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

    init(ssh: KnownHostsStore, rdp: KnownHostsStore) {
        _model = StateObject(wrappedValue: TrustedHostsModel(ssh: ssh, rdp: rdp))
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

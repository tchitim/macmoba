// "Discover on Network": browse Bonjour for machines offering SSH, Screen
// Sharing, RDP and the rest, and turn one into a session with a click. The
// browser runs only while this sheet is open.

import MacMobaCore
import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// Picking a service opens the normal editor pre-filled, so a name and login
    /// can be added before it is saved.
    let onPick: (SessionConfig) -> Void

    @State private var browser = BonjourBrowser()
    @State private var services: [DiscoveredService] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Discover on Network").font(.headline)
                if services.isEmpty {
                    ProgressView().controlSize(.small).padding(.leading, 6)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            Group {
                if services.isEmpty {
                    VStack(spacing: 6) {
                        Text("Looking for SSH, Screen Sharing, RDP, FTP…")
                            .foregroundStyle(.secondary)
                        Text("Nothing found yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(services) { service in
                        row(service)
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 340)
        .onAppear {
            browser.onChange = { services = $0 }
            browser.start()
        }
        .onDisappear { browser.stop() }
    }

    private func row(_ service: DiscoveredService) -> some View {
        HStack(spacing: 10) {
            Image(systemName: service.kind.sessionKind.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                Text("\(service.kind.sessionKind.displayName) · \(service.host):\(service.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add…") {
                onPick(service.makeSession())
                dismiss()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onPick(service.makeSession())
            dismiss()
        }
    }
}

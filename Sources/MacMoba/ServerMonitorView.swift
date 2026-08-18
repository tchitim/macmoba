// A one-glance "how's the box doing" readout for an SSH session: load, CPU,
// memory, uptime — MobaXterm's server-monitor, gathered on demand. It connects
// on its own (AppState.remoteStats), so it works from the sidebar without the
// session being open in a tab.

import MacMobaCore
import SwiftUI

struct ServerMonitorView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let session: SessionConfig

    @State private var stats: RemoteStats?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text(session.name).font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Text("\(session.username)@\(session.host):\(String(session.port))")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if let stats {
                grid(stats)
            } else if !loading {
                Text("No data yet.").foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh") { fetch() }.disabled(loading)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { if stats == nil { fetch() } }
    }

    @ViewBuilder private func grid(_ s: RemoteStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cpu = s.cpuUsedPercent { bar("CPU", value: cpu, label: pct(cpu)) }
            if let mem = s.memUsedPercent {
                bar("Memory", value: mem,
                    label: pct(mem) + memSuffix(s.memTotalKB))
            }
            if !s.loadAverages.isEmpty {
                row("Load", s.loadAverages.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            }
            if let uptime = s.uptimeText { row("Uptime", uptime) }
            if let users = s.users { row("Users", String(users)) }
        }
    }

    private func bar(_ title: String, value: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(label).font(.system(.caption, design: .monospaced))
            }
            ProgressView(value: max(0, min(100, value)), total: 100)
                .tint(value > 90 ? .red : value > 70 ? .orange : .accentColor)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    private func memSuffix(_ totalKB: Int?) -> String {
        guard let totalKB else { return "" }
        let gb = Double(totalKB) / 1_048_576
        return String(format: " of %.1f GB", gb)
    }

    private func fetch() {
        loading = true
        error = nil
        Task {
            do {
                let result = try await app.remoteStats(for: session)
                await MainActor.run { stats = result; loading = false }
            } catch {
                await MainActor.run {
                    self.error = "Could not reach the server: \(error)"
                    loading = false
                }
            }
        }
    }
}

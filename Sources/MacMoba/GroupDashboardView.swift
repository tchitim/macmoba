// The folder dashboard (P2-13): click a sidebar group and the inspector shows
// its whole fleet — every member with its health light, and one button to open
// them all. Complements the Overview (⇧⌘0), which shows what is OPEN; this
// shows what a folder HOLDS. Royal TSX's folder dashboard, sized to a panel.

import MacMobaCore
import SwiftUI

struct GroupDashboardView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState
    @EnvironmentObject var health: HealthMonitor
    let group: String

    // A folder is its subtree: members include every session underneath,
    // "Production/Linux" ones counted into "Production".
    private var members: [SessionConfig] {
        app.data.sessions.filter { GroupTree.contains(group, group: $0.group) }
    }

    private var healthCounts: (up: Int, down: Int, unknown: Int) {
        var up = 0, down = 0, unknown = 0
        for s in members where s.reachabilityTarget != nil {
            switch health.status[s.id] {
            case .up: up += 1
            case .down: down += 1
            case nil: unknown += 1
            }
        }
        return (up, down, unknown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group).font(.headline).lineLimit(2)
                    Text("\(members.count) session\(members.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if health.isEnabled {
                let counts = healthCounts
                HStack(spacing: 12) {
                    healthChip(count: counts.up, color: .green, label: "up")
                    healthChip(count: counts.down, color: .red, label: "down")
                    if counts.unknown > 0 {
                        healthChip(count: counts.unknown,
                                   color: .secondary.opacity(0.5), label: "unchecked")
                    }
                    Spacer()
                }
            }
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(members) { session in
                        memberRow(session)
                    }
                }
            }
            Divider()
            Button {
                // Every member becomes a tab; MultiExec is then one toggle away.
                for session in members { window.openTab(for: session) }
            } label: {
                Label("Connect All (\(members.count))", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(members.isEmpty)
        }
        .padding(14)
    }

    private func healthChip(count: Int, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count) \(label)").font(.caption)
        }
        .accessibilityLabel("\(count) \(label)")
    }

    private func memberRow(_ session: SessionConfig) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.sessionKind.symbolName)
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.name).font(.callout).lineLimit(1)
                Text(session.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if health.isEnabled, session.reachabilityTarget != nil {
                let color: Color = {
                    switch health.status[session.id] {
                    case .up: return .green
                    case .down: return .red
                    case nil: return .secondary.opacity(0.4)
                    }
                }()
                Circle().fill(color).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { window.openTab(for: session) }
        .onTapGesture(count: 1) {
            window.selectedSessionID = session.id
            window.selectedGroup = nil
        }
        .help("Double-click to connect")
    }
}

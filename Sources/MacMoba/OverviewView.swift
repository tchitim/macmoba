// The Overview: every open connection across every window, at a glance.
//
// One card per tab — a live thumbnail when the tab is on screen, a big kind
// glyph when it is a background tab that was never laid out, plus its name,
// where it goes and a status dot. Clicking a card brings that window forward
// with the tab selected. Handy once a few sessions are open across windows and
// the tab bars no longer tell the whole story.

import MacMobaCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// Bumped to recapture thumbnails; the cards read it so Refresh re-renders.
    @State private var generation = 0

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Overview").font(.headline)
                Spacer()
                Button { generation += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh thumbnails")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if app.allTabs.isEmpty {
                Spacer()
                Text("No open connections")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(app.allTabs) { tab in
                            OverviewCard(tab: tab, generation: generation) {
                                app.focus(tab: tab)
                                dismiss()
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 780, minHeight: 400, idealHeight: 560)
    }
}

private struct OverviewCard: View {
    @ObservedObject var tab: SessionTab
    let generation: Int
    let onOpen: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                thumbArea
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(tab.title).lineLimit(1)
                    Spacer()
                    Image(systemName: tab.kind.symbolName)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onAppear { thumbnail = tab.snapshot() }
        .onChange(of: generation) { _ in thumbnail = tab.snapshot() }
    }

    @ViewBuilder
    private var thumbArea: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: tab.kind.symbolName)
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var subtitle: String {
        let c = tab.config
        if tab.kind == .web { return c.webURL ?? c.host }
        return c.username.isEmpty ? "\(c.host):\(c.port)" : "\(c.username)@\(c.host):\(c.port)"
    }

    private var statusColor: Color {
        switch tab.aggregateState {
        case .connected: return .green
        case .connecting: return .yellow
        case .closed: return .red
        }
    }
}

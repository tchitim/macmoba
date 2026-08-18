// The strip under each terminal pane (P0-2): connection state on the left,
// transient app messages on the right. This is where MacMoba talks about a
// session — never inside the terminal buffer, which belongs to the remote.
//
// The left side is persistent and derives straight from the pane's state; a
// failed or dropped connection turns it red, and clicking it shows the full
// reason in a popover — replacing the multi-line errors that used to be
// printed into the scrollback.

import MacMobaCore
import SwiftUI

struct PaneStatusBar: View {
    @ObservedObject var pane: TerminalTab
    @State private var showReason = false

    var body: some View {
        HStack(spacing: 8) {
            stateSide
            Spacer(minLength: 12)
            messageSide
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - persistent connection state

    @ViewBuilder private var stateSide: some View {
        let (color, label, reason) = stateDescription
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(reason == nil ? Color.secondary : color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .contentShape(Rectangle())
        .onTapGesture { if reason != nil { showReason = true } }
        .popover(isPresented: $showReason, arrowEdge: .bottom) {
            // The full failure text, selectable — what used to be dumped into
            // the terminal.
            ScrollView {
                Text(stateDescription.reason ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 260)
        }
        .help(reason == nil ? "" : "Click for details")
    }

    private var stateDescription: (color: Color, label: String, reason: String?) {
        switch pane.state {
        case .connecting:
            return (.yellow, "Connecting to \(pane.statusTarget) …", nil)
        case .connected:
            return (.green, pane.statusTarget, nil)
        case .closed(let reason):
            return (.red, "Disconnected — \(pane.statusTarget)", reason)
        }
    }

    // MARK: - transient messages

    @ViewBuilder private var messageSide: some View {
        if let status = pane.status {
            Text(status.text)
                .foregroundStyle(status.level == .error ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .transition(.opacity)
                .onHover { pane.setStatusHovered($0) }
                .help(status.text)
        }
    }
}

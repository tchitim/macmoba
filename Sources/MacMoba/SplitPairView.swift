// AppKit-backed split container for terminal panes. SwiftUI's HSplitView
// gives a newly added child the minimum size instead of a fair share, so
// splits use NSSplitView with explicit even positions and proportional resize.
//
// N children rather than two: panes split along the same axis are laid out as
// siblings of ONE container. Nested two-way containers each halve their own
// space, so five panes came out 50/25/12.5/6.25/6.25 — one usable pane and a
// stack of slivers. See SplitLayout.

import AppKit
import MacMobaCore
import SwiftUI

final class EvenSplitView: NSSplitView {
    /// Set when the number of panes changes, so the next layout redistributes
    /// them evenly — and only then, or dragging a divider would be undone on
    /// the next pass.
    var needsEvenLayout = true
    private var lastArrangedCount = 0

    override func layout() {
        if arrangedSubviews.count != lastArrangedCount {
            lastArrangedCount = arrangedSubviews.count
            needsEvenLayout = true
        }
        let total = isVertical ? bounds.width : bounds.height
        if needsEvenLayout, bounds.width > 1, bounds.height > 1, arrangedSubviews.count > 1 {
            needsEvenLayout = false
            let positions = SplitLayout.evenDividerPositions(
                count: arrangedSubviews.count, total: total,
                dividerThickness: dividerThickness)
            for (index, position) in positions.enumerated() {
                setPosition(position, ofDividerAt: index)
            }
        }
        super.layout()
    }
}

struct SplitPairView: NSViewRepresentable {
    let axis: Axis
    /// Every pane on this axis, in order. Two or more.
    let children: [AnyView]

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var hosts: [NSHostingView<AnyView>] = []

        private static let minPane: CGFloat = 120

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(proposedMinimumPosition, Self.minPane)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            return min(proposedMaximumPosition, total - Self.minPane)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EvenSplitView {
        let splitView = EvenSplitView()
        // NSSplitView "vertical" means the divider is vertical → side by side.
        splitView.isVertical = (axis == .horizontal)
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        for child in children {
            let host = NSHostingView(rootView: child)
            context.coordinator.hosts.append(host)
            splitView.addArrangedSubview(host)
        }
        return splitView
    }

    func updateNSView(_ nsView: EvenSplitView, context: Context) {
        let coordinator = context.coordinator
        // The count changes when a pane is added or closed. Rebuilding the
        // hosting views then is what lets the layout even itself out again.
        if coordinator.hosts.count != children.count {
            for host in coordinator.hosts { nsView.removeArrangedSubview(host) }
            for host in coordinator.hosts { host.removeFromSuperview() }
            coordinator.hosts = children.map { child in
                let host = NSHostingView(rootView: child)
                nsView.addArrangedSubview(host)
                return host
            }
            nsView.needsEvenLayout = true
            nsView.needsLayout = true
            return
        }
        for (host, child) in zip(coordinator.hosts, children) {
            host.rootView = child
        }
    }
}

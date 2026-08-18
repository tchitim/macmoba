// Turning a tree of two-way splits into the rows a person actually sees.
//
// Splitting the same pane repeatedly builds a right-leaning tree:
//
//     split(A, split(B, split(C, split(D, E))))
//
// Rendered as nested containers that each divide their own space in half, that
// gives A half the window, B a quarter, C an eighth… which is why five panes
// come out as one big one and a stack of slivers. Flattening the chain into
// five siblings of ONE container makes them equal, and dividers still work
// because the container is a single N-way split.

import Foundation

public enum SplitLayout {
    /// Every node reachable from `node` along splits of the same axis.
    ///
    /// Generic over the tree so the pane type (which lives in the app target,
    /// wrapped around live terminals) does not have to be visible here.
    ///
    /// - Parameter decompose: returns the axis and the two children of a
    ///   split, or nil for a leaf.
    /// - Returns: the siblings, in order, left/top first. A leaf yields itself.
    public static func siblings<Node, Axis: Equatable>(
        of node: Node,
        axis: Axis,
        decompose: (Node) -> (axis: Axis, first: Node, second: Node)?
    ) -> [Node] {
        guard let parts = decompose(node), parts.axis == axis else {
            // A leaf, or a split along the OTHER axis — that one is a single
            // child here and flattens on its own terms further down.
            return [node]
        }
        return siblings(of: parts.first, axis: axis, decompose: decompose)
            + siblings(of: parts.second, axis: axis, decompose: decompose)
    }

    /// Where the dividers go so `count` panes share `total` equally.
    ///
    /// Positions are cumulative, as NSSplitView wants them, and each accounts
    /// for the dividers before it — without that the panes drift further apart
    /// the further down you go.
    public static func evenDividerPositions(count: Int, total: CGFloat,
                                            dividerThickness: CGFloat) -> [CGFloat] {
        guard count > 1, total > 0 else { return [] }
        let dividers = CGFloat(count - 1)
        let each = (total - dividers * dividerThickness) / CGFloat(count)
        guard each > 0 else { return [] }
        return (1..<count).map { index in
            CGFloat(index) * each + CGFloat(index - 1) * dividerThickness
        }
    }
}

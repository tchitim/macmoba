// Moving one item of a list in front of another.
//
// Trivial-looking and easy to get wrong: removing the dragged item first shifts
// everything after it left by one, so the insertion index is not the index you
// measured before the removal. Kept here so the arithmetic can be tested
// without a window.

import Foundation

public enum ListReorder {
    /// Moves `id` so that it sits next to `target`, in the direction the drag
    /// came from: dragging rightwards lands after the target, dragging
    /// leftwards lands before it. That is what makes a drag feel like it goes
    /// where you pointed.
    ///
    /// Returns the list unchanged if either id is missing, or if they are the
    /// same — a drop on yourself is not a move.
    public static func move<ID: Equatable>(_ id: ID, toward target: ID, in items: [ID]) -> [ID] {
        guard id != target,
              let from = items.firstIndex(of: id),
              let to = items.firstIndex(of: target)
        else { return items }

        var result = items
        let moved = result.remove(at: from)
        // Re-find the target: after the removal its index may have moved.
        guard let landing = result.firstIndex(of: target) else { return items }
        result.insert(moved, at: from < to ? landing + 1 : landing)
        return result
    }
}

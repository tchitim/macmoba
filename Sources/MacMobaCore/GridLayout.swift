// Laying panes out as a grid rather than a single stack.
//
// Rows of TWO, filled left to right and then downward. A terminal needs width
// far more than it needs height — 80 columns of text is the whole point — so
// three narrow columns are worse than two wide ones, and a fifth session
// belongs on a new row rather than stretched down the side of the window.

import Foundation

public enum GridLayout {
    /// The most panes placed side by side in one row.
    public static let panesPerRow = 2

    /// How many panes go in each row, top to bottom.
    ///
    /// Full rows first, so the odd one out is alone on the last row rather
    /// than making every row uneven.
    public static func rowSizes(for count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let full = count / panesPerRow
        let remainder = count % panesPerRow
        return Array(repeating: panesPerRow, count: full) + (remainder > 0 ? [remainder] : [])
    }

    /// The panes of each row, as indices into the original list.
    public static func rows(for count: Int) -> [[Int]] {
        var result: [[Int]] = []
        var next = 0
        for size in rowSizes(for: count) {
            result.append(Array(next..<(next + size)))
            next += size
        }
        return result
    }
}

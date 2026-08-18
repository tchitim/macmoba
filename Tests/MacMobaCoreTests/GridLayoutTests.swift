import XCTest

@testable import MacMobaCore

final class GridLayoutTests: XCTestCase {
    /// A pair is one row, side by side.
    func testTwoPanesShareOneRow() {
        XCTAssertEqual(GridLayout.rowSizes(for: 2), [2])
        XCTAssertEqual(GridLayout.rows(for: 2), [[0, 1]])
    }

    func testOneOrNoneIsNotAGrid() {
        XCTAssertEqual(GridLayout.rowSizes(for: 1), [1])
        XCTAssertEqual(GridLayout.rowSizes(for: 0), [])
        XCTAssertEqual(GridLayout.rows(for: 0), [])
    }

    /// Never more than two side by side: a terminal needs width, and three
    /// narrow columns are worse than two wide ones.
    func testNeverMoreThanTwoAcross() {
        for count in 1...40 {
            for size in GridLayout.rowSizes(for: count) {
                XCTAssertLessThanOrEqual(size, 2, "\(count) panes")
            }
        }
    }

    /// Five sessions: two rows of two, and the fifth alone on a third row.
    func testFiveSessionsPutTheFifthOnItsOwnRow() {
        XCTAssertEqual(GridLayout.rowSizes(for: 5), [2, 2, 1])
        XCTAssertEqual(GridLayout.rows(for: 5), [[0, 1], [2, 3], [4]])
    }

    func testRowsFillBeforeTheyOverflow() {
        XCTAssertEqual(GridLayout.rowSizes(for: 3), [2, 1])
        XCTAssertEqual(GridLayout.rowSizes(for: 4), [2, 2])
        XCTAssertEqual(GridLayout.rowSizes(for: 6), [2, 2, 2])
        XCTAssertEqual(GridLayout.rowSizes(for: 9), [2, 2, 2, 2, 1])
    }

    /// Only the LAST row may be short — otherwise the gap would appear in the
    /// middle of the window.
    func testOnlyTheLastRowCanBeShort() {
        for count in 1...40 {
            let sizes = GridLayout.rowSizes(for: count)
            for size in sizes.dropLast() {
                XCTAssertEqual(size, 2, "\(count) panes gave \(sizes)")
            }
        }
    }

    /// Every pane appears exactly once, in order.
    func testEveryPaneIsPlacedOnceInOrder() {
        for count in 1...40 {
            let flattened = GridLayout.rows(for: count).flatMap { $0 }
            XCTAssertEqual(flattened, Array(0..<count), "\(count) panes")
        }
    }
}

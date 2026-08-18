import XCTest

@testable import MacMobaCore

/// Five panes should be five equal rows, not one big pane and four slivers.
final class SplitLayoutTests: XCTestCase {
    /// A stand-in for the real pane tree, which holds live terminals.
    indirect enum Tree: Equatable {
        case leaf(String)
        case split(axis: String, first: Tree, second: Tree)
    }

    private func decompose(_ tree: Tree) -> (axis: String, first: Tree, second: Tree)? {
        if case .split(let axis, let first, let second) = tree {
            return (axis, first, second)
        }
        return nil
    }

    private func names(_ trees: [Tree]) -> [String] {
        trees.map { if case .leaf(let name) = $0 { return name } else { return "<split>" } }
    }

    func testALeafIsItsOwnOnlySibling() {
        XCTAssertEqual(names(SplitLayout.siblings(of: .leaf("a"), axis: "v",
                                                  decompose: decompose)), ["a"])
    }

    func testAPairFlattensToTwo() {
        let tree = Tree.split(axis: "v", first: .leaf("a"), second: .leaf("b"))
        XCTAssertEqual(names(SplitLayout.siblings(of: tree, axis: "v",
                                                  decompose: decompose)), ["a", "b"])
    }

    /// The shape you get by splitting the same pane five times — the one that
    /// rendered as 50/25/12.5/6.25/6.25.
    func testARightLeaningChainFlattensToAllFive() {
        let tree = Tree.split(axis: "v", first: .leaf("a"),
                    second: .split(axis: "v", first: .leaf("b"),
                             second: .split(axis: "v", first: .leaf("c"),
                                      second: .split(axis: "v", first: .leaf("d"),
                                               second: .leaf("e")))))
        XCTAssertEqual(names(SplitLayout.siblings(of: tree, axis: "v",
                                                  decompose: decompose)),
                       ["a", "b", "c", "d", "e"])
    }

    /// Splitting the FIRST pane each time leans the other way; order must
    /// still be top-to-bottom.
    func testALeftLeaningChainKeepsItsOrder() {
        let tree = Tree.split(axis: "v",
                              first: .split(axis: "v", first: .leaf("a"), second: .leaf("b")),
                              second: .leaf("c"))
        XCTAssertEqual(names(SplitLayout.siblings(of: tree, axis: "v",
                                                  decompose: decompose)), ["a", "b", "c"])
    }

    /// A split along the other axis is ONE child here — it divides its own
    /// space, and flattens on its own terms when it is rendered.
    func testTheOtherAxisIsNotFlattenedIn() {
        let inner = Tree.split(axis: "h", first: .leaf("b"), second: .leaf("c"))
        let tree = Tree.split(axis: "v", first: .leaf("a"), second: inner)
        let flattened = SplitLayout.siblings(of: tree, axis: "v", decompose: decompose)
        XCTAssertEqual(names(flattened), ["a", "<split>"])
        XCTAssertEqual(flattened.last, inner)

        // And that inner split flattens along its own axis.
        XCTAssertEqual(names(SplitLayout.siblings(of: inner, axis: "h",
                                                  decompose: decompose)), ["b", "c"])
    }

    /// Mixed nesting: a horizontal pair inside a vertical chain must not
    /// swallow the panes on either side of it.
    func testMixedNestingKeepsEachLevelSeparate() {
        let tree = Tree.split(axis: "v", first: .leaf("top"),
                    second: .split(axis: "v",
                             first: .split(axis: "h", first: .leaf("l"), second: .leaf("r")),
                             second: .leaf("bottom")))
        XCTAssertEqual(names(SplitLayout.siblings(of: tree, axis: "v",
                                                  decompose: decompose)),
                       ["top", "<split>", "bottom"])
    }

    // MARK: Divider positions

    func testTwoPanesSplitDownTheMiddle() {
        let positions = SplitLayout.evenDividerPositions(count: 2, total: 400,
                                                         dividerThickness: 0)
        XCTAssertEqual(positions, [200])
    }

    /// Each position has to account for the dividers before it, or the panes
    /// drift further apart the further down you go.
    func testFivePanesAreEqualOnceDividersAreCountedIn() {
        let total: CGFloat = 1000
        let thickness: CGFloat = 1
        let positions = SplitLayout.evenDividerPositions(count: 5, total: total,
                                                         dividerThickness: thickness)
        XCTAssertEqual(positions.count, 4)

        // Turn the positions back into pane heights and check they match.
        var heights: [CGFloat] = []
        var previousEnd: CGFloat = 0
        for position in positions {
            heights.append(position - previousEnd)
            previousEnd = position + thickness
        }
        heights.append(total - previousEnd)
        let expected = (total - 4 * thickness) / 5
        for height in heights {
            XCTAssertEqual(height, expected, accuracy: 0.001, "got \(heights)")
        }
    }

    func testDegenerateCasesProduceNoDividers() {
        XCTAssertTrue(SplitLayout.evenDividerPositions(count: 1, total: 500,
                                                       dividerThickness: 1).isEmpty)
        XCTAssertTrue(SplitLayout.evenDividerPositions(count: 3, total: 0,
                                                       dividerThickness: 1).isEmpty)
        // A window too small for the dividers themselves must not produce
        // negative positions.
        XCTAssertTrue(SplitLayout.evenDividerPositions(count: 5, total: 3,
                                                       dividerThickness: 1).isEmpty)
    }
}

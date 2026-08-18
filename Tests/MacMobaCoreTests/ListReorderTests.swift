import XCTest
@testable import MacMobaCore

/// Drag-to-reorder arithmetic. The direction-dependent landing spot and the
/// index shift after removal are both easy to get subtly wrong, and both look
/// fine until you drag across several positions.
final class ListReorderTests: XCTestCase {

    private let list = ["a", "b", "c", "d", "e"]

    func testDraggingRightwardsLandsAfterTheTarget() {
        // a past d → the tab you dragged should end up where you pointed.
        XCTAssertEqual(ListReorder.move("a", toward: "d", in: list),
                       ["b", "c", "d", "a", "e"])
    }

    func testDraggingLeftwardsLandsBeforeTheTarget() {
        XCTAssertEqual(ListReorder.move("e", toward: "b", in: list),
                       ["a", "e", "b", "c", "d"])
    }

    func testAdjacentSwapInEitherDirection() {
        XCTAssertEqual(ListReorder.move("b", toward: "c", in: list),
                       ["a", "c", "b", "d", "e"])
        XCTAssertEqual(ListReorder.move("c", toward: "b", in: list),
                       ["a", "c", "b", "d", "e"])
    }

    func testMovingToTheEnds() {
        XCTAssertEqual(ListReorder.move("c", toward: "a", in: list),
                       ["c", "a", "b", "d", "e"])
        XCTAssertEqual(ListReorder.move("c", toward: "e", in: list),
                       ["a", "b", "d", "e", "c"])
    }

    func testDroppingOnItselfChangesNothing() {
        XCTAssertEqual(ListReorder.move("c", toward: "c", in: list), list)
    }

    func testUnknownIdentifiersAreIgnored() {
        XCTAssertEqual(ListReorder.move("z", toward: "c", in: list), list)
        XCTAssertEqual(ListReorder.move("c", toward: "z", in: list), list)
        XCTAssertEqual(ListReorder.move("a", toward: "b", in: []), [])
    }

    /// Whatever happens, nothing may be lost or duplicated — a reorder that
    /// drops a tab would drop a live connection with it.
    func testEveryMovePreservesTheContents() {
        for from in list {
            for to in list {
                let result = ListReorder.move(from, toward: to, in: list)
                XCTAssertEqual(result.count, list.count, "\(from)→\(to) changed the count")
                XCTAssertEqual(Set(result), Set(list), "\(from)→\(to) lost or duplicated an item")
            }
        }
    }

    func testASingleItemListIsStable() {
        XCTAssertEqual(ListReorder.move("a", toward: "a", in: ["a"]), ["a"])
    }
}

import XCTest
@testable import MacMobaCore

/// Reopening your sessions is not reopening your window: three shells beside a
/// remote desktop used to come back as four unrelated tabs.
final class PaneLayoutTests: XCTestCase {

    private let a = PaneLayout.leaf(sessionID: "a")
    private let b = PaneLayout.leaf(sessionID: "b")
    private let c = PaneLayout.leaf(sessionID: "c")

    func testALayoutSurvivesEncoding() throws {
        let layout = WorkspaceLayout(tabs: [
            .split(vertical: false, first: a, second: .split(vertical: true, first: b, second: c))
        ])
        let restored = try XCTUnwrap(WorkspaceLayout.decoded(from: layout.encoded()))
        XCTAssertEqual(restored, layout)
    }

    /// A session deleted since last launch should cost its pane, not the
    /// arrangement around it.
    func testADeletedSessionCollapsesItsSplit() {
        let layout = PaneLayout.split(vertical: false, first: a, second: b)
        XCTAssertEqual(layout.pruned(keeping: ["a"]), a)
        XCTAssertEqual(layout.pruned(keeping: ["b"]), b)
    }

    func testPruningKeepsTheRestOfTheTree() {
        let layout = PaneLayout.split(vertical: false, first: a,
                                      second: .split(vertical: true, first: b, second: c))
        XCTAssertEqual(layout.pruned(keeping: ["a", "c"]),
                       .split(vertical: false, first: a, second: c))
    }

    func testATabWithNothingLeftIsNotRestored() {
        let layout = WorkspaceLayout(tabs: [.split(vertical: false, first: a, second: b), c])
        XCTAssertEqual(layout.restorable(available: ["c"]), WorkspaceLayout(tabs: [c]))
    }

    /// A gap exists to hold space beside a real pane; a layout of nothing but
    /// gaps would restore a tab you cannot type into and did not ask for.
    func testGapsAloneAreNotATab() {
        XCTAssertNil(PaneLayout.empty.pruned(keeping: ["a"]))
        XCTAssertNil(PaneLayout.split(vertical: false, first: .empty, second: .empty)
            .pruned(keeping: ["a"]))
    }

    func testTheOrderOfPanesIsKept() {
        let layout = PaneLayout.split(vertical: false, first: a,
                                      second: .split(vertical: true, first: b, second: c))
        XCTAssertEqual(layout.sessionIDs, ["a", "b", "c"])
    }

    /// Updating must not lose the workspace someone had open: the old format
    /// was a flat list of session ids, one tab each.
    func testTheOlderFlatFormatStillOpens() {
        XCTAssertEqual(WorkspaceLayout.fromSessionIDs(["a", "b"]),
                       WorkspaceLayout(tabs: [a, b]))
    }

    func testUnreadableDataIsNotALayout() {
        XCTAssertNil(WorkspaceLayout.decoded(from: nil))
        XCTAssertNil(WorkspaceLayout.decoded(from: Data("not json".utf8)))
    }
}

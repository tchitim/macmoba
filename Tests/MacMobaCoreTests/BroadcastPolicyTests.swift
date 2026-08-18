import XCTest

@testable import MacMobaCore

final class BroadcastPolicyTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    private func pane(_ id: UUID, connected: Bool = true,
                      inGroup: Bool = true) -> BroadcastPane {
        BroadcastPane(id: id, isConnected: connected, receivesBroadcast: inGroup)
    }

    func testEveryConnectedPaneInTheGroupReceives() {
        let targets = BroadcastPolicy.targets(typedIn: a,
                                              panes: [pane(a), pane(b), pane(c)])
        XCTAssertEqual(targets, [a, b, c])
    }

    func testAnExcludedPaneIsSkipped() {
        let targets = BroadcastPolicy.targets(
            typedIn: a, panes: [pane(a), pane(b, inGroup: false), pane(c)])
        XCTAssertEqual(targets, [a, c])
    }

    /// The trap: typing into a pane you took OUT of the group must still reach
    /// that pane, or the terminal appears to ignore you.
    func testTypingIntoAnExcludedPaneStillReachesIt() {
        let targets = BroadcastPolicy.targets(
            typedIn: b, panes: [pane(a), pane(b, inGroup: false), pane(c)])
        XCTAssertTrue(targets.contains(b), "your own keystrokes must reach your own terminal")
        XCTAssertEqual(targets, [a, b, c])
    }

    /// …but that is the only pane the exception applies to.
    func testTheExceptionDoesNotLeakToOtherExcludedPanes() {
        let targets = BroadcastPolicy.targets(
            typedIn: b, panes: [pane(a, inGroup: false), pane(b, inGroup: false), pane(c)])
        XCTAssertEqual(targets, [b, c])
    }

    func testDisconnectedPanesAreNeverWrittenTo() {
        let targets = BroadcastPolicy.targets(
            typedIn: a, panes: [pane(a), pane(b, connected: false), pane(c)])
        XCTAssertEqual(targets, [a, c])
    }

    /// Even the pane being typed into: if it is not connected there is nothing
    /// to write to.
    func testADisconnectedOriginGetsNothing() {
        let targets = BroadcastPolicy.targets(
            typedIn: b, panes: [pane(a), pane(b, connected: false)])
        XCTAssertEqual(targets, [a])
    }

    func testOrderIsPreservedAndNothingIsDuplicated() {
        let targets = BroadcastPolicy.targets(typedIn: c, panes: [pane(a), pane(b), pane(c)])
        XCTAssertEqual(targets, [a, b, c])
        XCTAssertEqual(Set(targets).count, targets.count)
    }

    func testNoOriginIsFine() {
        let targets = BroadcastPolicy.targets(
            typedIn: nil, panes: [pane(a), pane(b, inGroup: false)])
        XCTAssertEqual(targets, [a])
    }

    // MARK: Status

    func testPartialIsTrueOnlyWhenSomethingConnectedIsExcluded() {
        XCTAssertFalse(BroadcastPolicy.isPartial([pane(a), pane(b)]))
        XCTAssertTrue(BroadcastPolicy.isPartial([pane(a), pane(b, inGroup: false)]))
        // A disconnected pane being out of the group is not the user excluding it.
        XCTAssertFalse(BroadcastPolicy.isPartial([pane(a), pane(b, connected: false,
                                                              inGroup: false)]))
        XCTAssertFalse(BroadcastPolicy.isPartial([]))
    }

    func testReachCountsOnlyConnectedGroupMembers() {
        XCTAssertEqual(BroadcastPolicy.reach([pane(a), pane(b), pane(c)]), 3)
        XCTAssertEqual(BroadcastPolicy.reach([pane(a), pane(b, inGroup: false)]), 1)
        XCTAssertEqual(BroadcastPolicy.reach([pane(a, connected: false)]), 0)
    }
}

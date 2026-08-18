import XCTest

@testable import MacMobaCore

final class WorkspaceRestoreTests: XCTestCase {
    // MARK: - restorableIDs

    func testKeepsOrderAndOnlyExisting() {
        let ids = WorkspaceRestore.restorableIDs(saved: ["c", "a", "b"],
                                                 available: ["a", "b", "c"])
        XCTAssertEqual(ids, ["c", "a", "b"])
    }

    func testDropsSessionsThatNoLongerExist() {
        // "b" was deleted since last launch: it does not come back.
        let ids = WorkspaceRestore.restorableIDs(saved: ["a", "b", "c"],
                                                 available: ["a", "c"])
        XCTAssertEqual(ids, ["a", "c"])
    }

    func testDeduplicates() {
        let ids = WorkspaceRestore.restorableIDs(saved: ["a", "a", "b", "a"],
                                                 available: ["a", "b"])
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testEmptySavedGivesEmpty() {
        XCTAssertEqual(WorkspaceRestore.restorableIDs(saved: [], available: ["a"]), [])
    }

    func testNothingAvailableGivesEmpty() {
        XCTAssertEqual(WorkspaceRestore.restorableIDs(saved: ["a", "b"], available: []), [])
    }

    // MARK: - shouldReconnect

    func testReconnectsWhatWasConnected() {
        XCTAssertTrue(WakeReconnectPolicy.shouldReconnect(
            wasConnectedAtSleep: true, closedByUserSinceSleep: false))
    }

    func testDoesNotReconnectWhatWasNotConnected() {
        XCTAssertFalse(WakeReconnectPolicy.shouldReconnect(
            wasConnectedAtSleep: false, closedByUserSinceSleep: false))
    }

    /// The user closing a pane while asleep wins — waking must not resurrect it.
    func testDoesNotFightAUserClose() {
        XCTAssertFalse(WakeReconnectPolicy.shouldReconnect(
            wasConnectedAtSleep: true, closedByUserSinceSleep: true))
    }
}

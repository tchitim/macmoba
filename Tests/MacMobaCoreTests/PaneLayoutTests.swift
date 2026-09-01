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

    // MARK: - The local shell

    /// It depends on no vault entry, so nothing can prune it away — the bug
    /// that would look like "my shell pane vanished after a restart".
    func testALocalShellSurvivesPruning() {
        let layout = PaneLayout.split(vertical: false,
                                      first: .leaf(sessionID: "a"),
                                      second: .localShell)
        XCTAssertEqual(layout.pruned(keeping: ["a"]), layout)
        // Even when every session beside it is gone.
        XCTAssertEqual(layout.pruned(keeping: []), .localShell)
    }

    /// It is not a session, so it must not be asked for as one. A local shell
    /// reported here would be looked up in the vault and found missing.
    func testALocalShellIsNotASessionToOpen() {
        XCTAssertEqual(PaneLayout.localShell.sessionIDs, [])
        XCTAssertEqual(PaneLayout.split(vertical: true,
                                        first: .localShell,
                                        second: .leaf(sessionID: "a")).sessionIDs, ["a"])
    }

    func testALocalShellSurvivesEncoding() throws {
        let layout = PaneLayout.split(vertical: true,
                                      first: .localShell,
                                      second: .localShell)
        let data = try JSONEncoder().encode(WorkspaceLayout(tabs: [layout]))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceLayout.self, from: data).tabs, [layout])
    }

    /// A tab of nothing but shells is still a tab worth reopening, unlike one
    /// of nothing but gaps.
    func testATabOfOnlyLocalShellsIsRestored() {
        XCTAssertEqual(PaneLayout.localShell.pruned(keeping: []), .localShell)
        XCTAssertNil(PaneLayout.empty.pruned(keeping: []))
    }

    /// The whole point: a tab holding only shells has no session id, and the
    /// workspace must not read that as "nothing to reopen".
    func testAShellOnlyTabSurvivesAWorkspaceSave() {
        let workspace = WorkspaceLayout(tabs: [.localShell, .leaf(sessionID: "a")])
        XCTAssertEqual(workspace.restorable(available: ["a"]).tabs,
                       [.localShell, .leaf(sessionID: "a")])
        // And still, once the only real session is deleted.
        XCTAssertEqual(workspace.restorable(available: []).tabs, [.localShell])
    }

    func testContainsLocalShellFindsNestedOnes() {
        XCTAssertTrue(PaneLayout.split(vertical: false,
                                       first: .leaf(sessionID: "a"),
                                       second: .split(vertical: true,
                                                      first: .localShell,
                                                      second: .empty)).containsLocalShell)
        XCTAssertFalse(PaneLayout.split(vertical: false,
                                        first: .leaf(sessionID: "a"),
                                        second: .empty).containsLocalShell)
    }
}

import XCTest
@testable import MacMobaCore

final class GroupTreeTests: XCTestCase {

    // The user's own example: one project, Windows and Linux folders inside.
    func testProjectWithTwoSubfolders() {
        let rows = GroupTree.displayRows(groups: ["Production/Windows", "Production/Linux"])
        XCTAssertEqual(rows.map(\.path), ["Production", "Production/Linux", "Production/Windows"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
        XCTAssertEqual(rows.map(\.name), ["Production", "Linux", "Windows"])
    }

    func testImpliedParentAppearsOnce() {
        // Sessions directly in the parent AND in a child: one parent row.
        let rows = GroupTree.displayRows(groups: ["P", "P/Sub", "P/Sub/Deep"])
        XCTAssertEqual(rows.map(\.path), ["P", "P/Sub", "P/Sub/Deep"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
    }

    func testDepthFirstOrderAcrossSiblings() {
        let rows = GroupTree.displayRows(groups: ["B/x", "A", "B", "A/z"])
        XCTAssertEqual(rows.map(\.path), ["A", "A/z", "B", "B/x"])
    }

    func testCollapsedAncestorHidesDescendantsButNotItself() {
        let rows = GroupTree.displayRows(groups: ["P/Win", "P/Linux", "Q/x"],
                                         collapsed: ["P"])
        XCTAssertEqual(rows.map(\.path), ["P", "Q", "Q/x"],
                       "P stays visible; its children do not")
    }

    func testCollapseDeepInside() {
        let rows = GroupTree.displayRows(groups: ["A/B/C/D"], collapsed: ["A/B"])
        XCTAssertEqual(rows.map(\.path), ["A", "A/B"])
    }

    func testAncestorsAndParent() {
        XCTAssertEqual(GroupTree.ancestors(of: "A/B/C"), ["A", "A/B"])
        XCTAssertEqual(GroupTree.parent(of: "A/B/C"), "A/B")
        XCTAssertNil(GroupTree.parent(of: "A"))
    }

    func testContainsDirectAndNested() {
        XCTAssertTrue(GroupTree.contains("Production", group: "Production"))
        XCTAssertTrue(GroupTree.contains("Production", group: "Production/Linux"))
        XCTAssertFalse(GroupTree.contains("Production", group: "Production2"),
                       "prefix of the NAME is not containment")
        XCTAssertFalse(GroupTree.contains("Production", group: nil))
    }

    // MARK: - explicitly created folders (New Subfolder…)

    /// The whole point of the folders list: a folder with nothing in it yet.
    func testEmptyFolderShowsWithNoSessions() {
        let rows = GroupTree.displayRows(groups: [], folders: ["Staging"])
        XCTAssertEqual(rows.map(\.path), ["Staging"])
    }

    func testEmptySubfolderAppearsUnderItsParent() {
        let rows = GroupTree.displayRows(groups: ["Production/Linux"],
                                         folders: ["Production/Windows"])
        XCTAssertEqual(rows.map(\.path), ["Production", "Production/Linux", "Production/Windows"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
    }

    /// An explicit folder is not listed twice once a session moves into it.
    func testFolderAlsoNamedBySessionAppearsOnce() {
        let rows = GroupTree.displayRows(groups: ["P/Sub"], folders: ["P/Sub"])
        XCTAssertEqual(rows.map(\.path), ["P", "P/Sub"])
    }

    func testCollapsedParentHidesEmptySubfolder() {
        let rows = GroupTree.displayRows(groups: [], folders: ["P/Empty"],
                                         collapsed: ["P"])
        XCTAssertEqual(rows.map(\.path), ["P"])
    }

    // MARK: - childPath (the name typed into "New Subfolder…")

    func testChildPathUnderParentAndAtTopLevel() {
        XCTAssertEqual(GroupTree.childPath(of: "Production", name: "Windows"), "Production/Windows")
        XCTAssertEqual(GroupTree.childPath(of: nil, name: "Lab"), "Lab")
        XCTAssertEqual(GroupTree.childPath(of: "", name: "Lab"), "Lab")
    }

    func testChildPathTrimsAndRejectsEmpty() {
        XCTAssertEqual(GroupTree.childPath(of: "P", name: "  Web  "), "P/Web")
        XCTAssertNil(GroupTree.childPath(of: "P", name: "   "))
        XCTAssertNil(GroupTree.childPath(of: nil, name: ""))
    }

    /// A slash in the NAME would silently create extra nesting — one component.
    func testChildPathStripsSlashesFromTheName() {
        XCTAssertEqual(GroupTree.childPath(of: "P", name: "a/b"), "P/a b")
    }

    func testRenameMovesSubtree() {
        XCTAssertEqual(GroupTree.rename("P", from: "P", to: "Proj"), "Proj")
        XCTAssertEqual(GroupTree.rename("P/Linux", from: "P", to: "Proj"), "Proj/Linux")
        XCTAssertEqual(GroupTree.rename("P2/x", from: "P", to: "Proj"), "P2/x",
                       "a sibling sharing the name prefix must not move")
        XCTAssertEqual(GroupTree.rename("Other", from: "P", to: "Proj"), "Other")
    }
}

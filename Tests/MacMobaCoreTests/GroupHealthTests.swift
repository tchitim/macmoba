import XCTest
@testable import MacMobaCore

/// Collapsing a folder hides its members' lights, which is when knowing
/// whether something is down matters most.
final class GroupHealthTests: XCTestCase {

    func testOneFailureMarksTheFolder() {
        let statuses: [Reachability?] = [.up(latencyMs: 4), .down(reason: "refused"), .up(latencyMs: 9)]
        XCTAssertEqual(GroupHealth.summary(of: statuses), .down(count: 1))
    }

    func testFailuresAreCounted() {
        let statuses: [Reachability?] = [.down(reason: "a"), .down(reason: "b"), .up(latencyMs: 1)]
        XCTAssertEqual(GroupHealth.summary(of: statuses), .down(count: 2))
    }

    func testEverythingAnsweringIsQuietlyFine() {
        XCTAssertEqual(GroupHealth.summary(of: [.up(latencyMs: 1), .up(latencyMs: 2)]), .allUp)
    }

    /// A light that means "no information" teaches people to ignore lights, so
    /// an unchecked folder gets no mark at all.
    func testNothingCheckedIsNotAStatus() {
        XCTAssertEqual(GroupHealth.summary(of: [nil, nil]), .unknown)
        XCTAssertEqual(GroupHealth.summary(of: []), .unknown)
    }

    /// A folder where some members are checked and the rest are not — a jump
    /// host group, say — reports on what is actually known.
    func testPartialKnowledgeReportsWhatIsKnown() {
        XCTAssertEqual(GroupHealth.summary(of: [.up(latencyMs: 3), nil, nil]), .allUp)
        XCTAssertEqual(GroupHealth.summary(of: [nil, .down(reason: "x")]), .down(count: 1))
    }
}

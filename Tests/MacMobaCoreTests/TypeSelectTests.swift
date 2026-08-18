import XCTest
@testable import MacMobaCore

final class TypeSelectTests: XCTestCase {

    // MARK: - the buffer

    func testQuickKeystrokesBuildOnePrefix() {
        var buffer = TypeSelectBuffer(timeout: 1)
        XCTAssertEqual(buffer.append("w", at: 0), "w")
        XCTAssertEqual(buffer.append("e", at: 0.2), "we")
        XCTAssertEqual(buffer.append("b", at: 0.5), "web")
    }

    /// A pause starts a fresh search — otherwise a letter typed a minute later
    /// extends a stale prefix and matches nothing.
    func testPauseStartsOver() {
        var buffer = TypeSelectBuffer(timeout: 1)
        buffer.append("w", at: 0)
        buffer.append("e", at: 0.2)
        XCTAssertEqual(buffer.append("d", at: 5), "d")
    }

    func testTimeoutBoundaryIsInclusive() {
        var buffer = TypeSelectBuffer(timeout: 1)
        buffer.append("a", at: 0)
        XCTAssertEqual(buffer.append("b", at: 1.0), "b", "exactly at the timeout is a new search")
        XCTAssertEqual(buffer.append("c", at: 1.5), "bc", "just under it keeps building")
    }

    func testResetClearsThePrefix() {
        var buffer = TypeSelectBuffer()
        buffer.append("x", at: 0)
        buffer.reset()
        XCTAssertEqual(buffer.prefix, "")
        XCTAssertEqual(buffer.append("y", at: 0.1), "y")
    }

    func testOnlyPrintableCharactersAreCollected() {
        XCTAssertTrue(TypeSelectBuffer.isSearchable("a"))
        XCTAssertTrue(TypeSelectBuffer.isSearchable("7"))
        XCTAssertTrue(TypeSelectBuffer.isSearchable("-"))
        XCTAssertFalse(TypeSelectBuffer.isSearchable(" "), "space scrolls a list, not searches")
        XCTAssertFalse(TypeSelectBuffer.isSearchable("\n"))
        XCTAssertFalse(TypeSelectBuffer.isSearchable("\t"))
    }

    // MARK: - matching

    private let names = ["alpha", "Arch", "beta", "app-server", "Zulu"]

    func testPrefixMatchIsCaseInsensitive() {
        XCTAssertEqual(TypeSelect.match(prefix: "ar", in: names, current: nil), 1)
        XCTAssertEqual(TypeSelect.match(prefix: "AR", in: names, current: nil), 1)
        XCTAssertEqual(TypeSelect.match(prefix: "be", in: names, current: nil), 2)
    }

    /// Tapping the same letter walks through everything starting with it.
    func testSingleLetterCyclesThroughMatches() {
        // "a" matches alpha(0), Arch(1), app-server(3).
        XCTAssertEqual(TypeSelect.match(prefix: "a", in: names, current: nil), 0)
        XCTAssertEqual(TypeSelect.match(prefix: "a", in: names, current: 0), 1)
        XCTAssertEqual(TypeSelect.match(prefix: "a", in: names, current: 1), 3)
        XCTAssertEqual(TypeSelect.match(prefix: "a", in: names, current: 3), 0, "wraps around")
    }

    /// A longer prefix searches from the top, so refining what you typed does
    /// not skip past the match you were aiming at.
    func testLongerPrefixSearchesFromTheTop() {
        XCTAssertEqual(TypeSelect.match(prefix: "al", in: names, current: 3), 0)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(TypeSelect.match(prefix: "q", in: names, current: nil))
        XCTAssertNil(TypeSelect.match(prefix: "alphabet", in: names, current: nil))
    }

    func testEmptyInputsAreSafe() {
        XCTAssertNil(TypeSelect.match(prefix: "", in: names, current: nil))
        XCTAssertNil(TypeSelect.match(prefix: "a", in: [], current: nil))
    }
}

import XCTest
@testable import MacMobaCore

/// Rules typed by hand decide where a connection actually goes, so what the
/// parser refuses matters as much as what it accepts.
final class HostOverridesTests: XCTestCase {
    func testMapsAName() {
        let o = HostOverrides.parse("cp-sim.dev.crp.iclnet2.hk = 10.26.132.82")
        XCTAssertEqual(o.resolve("cp-sim.dev.crp.iclnet2.hk"), "10.26.132.82")
    }

    /// Anything unlisted must go through untouched, or one rule would break
    /// every other site in the tab.
    func testLeavesEverythingElseAlone() {
        let o = HostOverrides.parse("a.example = 10.0.0.1")
        XCTAssertEqual(o.resolve("b.example"), "b.example")
        XCTAssertEqual(o.resolve("10.0.0.9"), "10.0.0.9")
    }

    /// Host names are case-insensitive; a rule that missed on capitalisation
    /// would look exactly like no rule at all.
    func testMatchIsCaseInsensitive() {
        let o = HostOverrides.parse("CP-Sim.Dev = 10.0.0.5")
        XCTAssertEqual(o.resolve("cp-sim.dev"), "10.0.0.5")
        XCTAssertEqual(o.resolve("CP-SIM.DEV"), "10.0.0.5")
    }

    func testAcceptsEitherSeparatorAndOddSpacing() {
        for line in ["a.example = 10.0.0.1", "a.example=10.0.0.1",
                     "a.example    10.0.0.1", "\ta.example\t=\t10.0.0.1  "] {
            XCTAssertEqual(HostOverrides.parse(line).resolve("a.example"), "10.0.0.1", line)
        }
    }

    func testCommentsAndBlankLinesAreSkipped() {
        let o = HostOverrides.parse("""
        # turned off for now
        # a.example = 10.0.0.1

        b.example = 10.0.0.2   # why
        """)
        XCTAssertEqual(o.resolve("a.example"), "a.example", "a commented rule must not apply")
        XCTAssertEqual(o.resolve("b.example"), "10.0.0.2")
    }

    /// A line that is not a pair is skipped rather than half-read: acting on
    /// a guess here sends traffic somewhere nobody asked for.
    func testMalformedLinesAreIgnored() {
        for junk in ["justaname", "a b c", "= 10.0.0.1", "a.example =", "   "] {
            let o = HostOverrides.parse(junk)
            XCTAssertTrue(o.isEmpty, "should have ignored: \(junk)")
        }
    }

    func testEmptyInputMapsNothing() {
        XCTAssertTrue(HostOverrides.parse("").isEmpty)
        XCTAssertEqual(HostOverrides.parse("").resolve("a.example"), "a.example")
    }

    /// Round-trips, so an edited list can be stored and read back.
    func testTextRoundTrips() {
        let text = "a.example = 10.0.0.1\nb.example = 10.0.0.2"
        XCTAssertEqual(HostOverrides.parse(text).text, text)
    }
}

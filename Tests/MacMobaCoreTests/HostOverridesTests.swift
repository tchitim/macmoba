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

// MARK: - Stored on the session

extension HostOverridesTests {
    /// The rules survive a save/load, and survive it as TEXT.
    ///
    /// Storing the parsed map would quietly delete a line the parser skipped —
    /// a typo would vanish from the box instead of sitting there to be fixed.
    func testRulesRoundTripThroughTheVaultAsTypedText() throws {
        var config = SessionConfig(name: "sim", host: "", port: 0, username: "")
        config.kind = "web"
        config.webURL = "https://cp-sim.dev.crp.iclnet2.hk/"
        config.hostOverrides = "cp-sim.dev.crp.iclnet2.hk = 10.26.132.82\nnot a rule at all\n"

        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(SessionConfig.self, from: data)

        XCTAssertEqual(back.hostOverrides, config.hostOverrides)
        XCTAssertEqual(HostOverrides.parse(back.hostOverrides ?? "")
            .resolve("cp-sim.dev.crp.iclnet2.hk"), "10.26.132.82")
    }

    /// A session with no rules produces the empty set, not a crash or a
    /// map with one blank entry.
    func testNoRulesIsEmpty() {
        let config = SessionConfig(name: "plain", host: "h", port: 22, username: "u")
        XCTAssertNil(config.hostOverrides)
        XCTAssertTrue(HostOverrides.parse(config.hostOverrides ?? "").isEmpty)
    }

    /// Only the host being dialled is substituted. Everything else that
    /// travels — and in particular the name the browser puts in SNI and the
    /// Host header — is untouched, which is the entire reason this maps
    /// instead of rewriting the URL.
    func testOnlyTheDialledAddressChanges() {
        let rules = HostOverrides.parse("cp-sim.dev.crp.iclnet2.hk = 10.26.132.82")
        XCTAssertEqual(rules.resolve("cp-sim.dev.crp.iclnet2.hk"), "10.26.132.82")
        // A different name on the same tunnel is left alone.
        XCTAssertEqual(rules.resolve("other.dev.crp.iclnet2.hk"),
                       "other.dev.crp.iclnet2.hk")
    }
}

// MARK: - A port in the rule

extension HostOverridesTests {
    /// `name = address:port` moves both, the way Chrome's flag does.
    func testARuleCanNameAPort() {
        let rules = HostOverrides.parse("sim.internal = 10.26.132.82:8443")
        let target = rules.resolve("sim.internal", port: 443)
        XCTAssertEqual(target.host, "10.26.132.82")
        XCTAssertEqual(target.port, 8443)
    }

    /// Without one, the port asked for is kept. This is the common case: the
    /// service is where the URL says, only the name cannot be resolved.
    func testWithoutAPortTheRequestedOneIsKept() {
        let rules = HostOverrides.parse("sim.internal = 10.26.132.82")
        XCTAssertEqual(rules.resolve("sim.internal", port: 8080).port, 8080)
        XCTAssertEqual(rules.resolve("sim.internal", port: 443).port, 443)
    }

    /// A bare IPv6 literal is full of colons and none of them is a port.
    /// Splitting on the last one would dial a truncated address.
    func testABareIPv6LiteralIsNotSplit() {
        let rules = HostOverrides.parse("sim.internal = fd00::1")
        let target = rules.resolve("sim.internal", port: 443)
        XCTAssertEqual(target.host, "fd00::1")
        XCTAssertEqual(target.port, 443)
    }

    /// Brackets are what make the last colon a separator — the same rule a URL
    /// follows, so there is nothing new to learn.
    func testABracketedIPv6LiteralCanCarryAPort() {
        let rules = HostOverrides.parse("sim.internal = [fd00::1]:8443")
        let target = rules.resolve("sim.internal", port: 443)
        XCTAssertEqual(target.host, "fd00::1")
        XCTAssertEqual(target.port, 8443)
    }

    /// Something that is not a port is not treated as one. Reading "8443x" as
    /// 8443 would dial somewhere the rule never named.
    func testRubbishAfterTheColonIsNotAPort() {
        for bad in ["10.0.0.1:8443x", "10.0.0.1:", "10.0.0.1:0", "10.0.0.1:99999"] {
            let target = HostOverrides.parse("sim.internal = \(bad)")
                .resolve("sim.internal", port: 443)
            XCTAssertEqual(target.host, bad, "\(bad) should be left whole")
            XCTAssertEqual(target.port, 443, "\(bad) should not change the port")
        }
    }

    /// The text form round-trips, brackets and all, so editing a saved rule
    /// shows what was saved.
    func testTheTextFormRoundTrips() {
        for rule in ["a = 10.0.0.1", "a = 10.0.0.1:8443", "a = [fd00::1]:8443"] {
            XCTAssertEqual(HostOverrides.parse(rule).text, rule)
        }
    }
}

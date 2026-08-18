import XCTest

@testable import MacMobaCore

final class SessionColorTests: XCTestCase {
    func testNoneHasNoColour() {
        XCTAssertNil(SessionColor.none.hex)
        XCTAssertNil(SessionColor.none.rgb)
    }

    func testEveryNamedColourHasSixHexDigits() {
        for c in SessionColor.allCases where c != .none {
            let hex = try? XCTUnwrap(c.hex)
            XCTAssertEqual(hex?.count, 6, "\(c)")
            XCTAssertNotNil(UInt32(hex ?? "", radix: 16), "\(c) is not valid hex")
        }
    }

    func testRGBDecodesTheHex() {
        // 0A84FF -> (10, 132, 255)/255
        let rgb = try? XCTUnwrap(SessionColor.blue.rgb)
        XCTAssertEqual(rgb?.red ?? -1, 10.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(rgb?.green ?? -1, 132.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(rgb?.blue ?? -1, 255.0 / 255.0, accuracy: 0.001)
    }

    func testUnknownRawValueFallsBackToNone() {
        var s = SessionConfig(name: "s", host: "h", username: "u")
        s.color = "chartreuse"
        XCTAssertEqual(s.colorTag, .none)
        s.color = nil
        XCTAssertEqual(s.colorTag, .none)
        s.color = "green"
        XCTAssertEqual(s.colorTag, .green)
    }

    // MARK: - back-compat decoding

    func testVaultWithoutNewSessionKeysStillDecodes() throws {
        let json = """
        {"sessions":[{"id":"a","name":"n","host":"h","port":22,"username":"u",
        "authType":"password"}]}
        """
        let data = try JSONDecoder().decode(VaultData.self, from: Data(json.utf8))
        let s = data.sessions[0]
        XCTAssertNil(s.notes)
        XCTAssertNil(s.tags)
        XCTAssertEqual(s.colorTag, .none)
    }

    func testNotesColorTagsRoundTrip() throws {
        var s = SessionConfig(name: "s", host: "h", username: "u")
        s.notes = "note"
        s.color = "orange"
        s.tags = ["a", "b"]
        let decoded = try JSONDecoder().decode(SessionConfig.self,
                                               from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
        XCTAssertEqual(decoded.colorTag, .orange)
    }
}

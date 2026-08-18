import XCTest

@testable import MacMobaCore

final class OnConnectScriptTests: XCTestCase {
    func testNilOrBlankGivesNothing() {
        XCTAssertEqual(OnConnectScript.keystrokes(nil), "")
        XCTAssertEqual(OnConnectScript.keystrokes(""), "")
        XCTAssertEqual(OnConnectScript.keystrokes("   \n  \n"), "")
    }

    func testSingleCommandGetsTrailingReturn() {
        XCTAssertEqual(OnConnectScript.keystrokes("whoami"), "whoami\r")
    }

    func testEachLineBecomesReturn() {
        XCTAssertEqual(OnConnectScript.keystrokes("cd /var/log\ntail -f syslog"),
                       "cd /var/log\rtail -f syslog\r")
    }

    func testCRLFNormalizedToCR() {
        XCTAssertEqual(OnConnectScript.keystrokes("a\r\nb"), "a\rb\r")
    }

    func testAlreadyTrailingReturnNotDoubled() {
        XCTAssertEqual(OnConnectScript.keystrokes("run\n"), "run\r")
    }

    // MARK: - back-compat

    func testVaultWithoutOnConnectStillDecodes() throws {
        let json = """
        {"sessions":[{"id":"a","name":"n","host":"h","port":22,"username":"u",
        "authType":"password"}]}
        """
        let data = try JSONDecoder().decode(VaultData.self, from: Data(json.utf8))
        XCTAssertNil(data.sessions[0].onConnectCommands)
    }

    func testOnConnectRoundTrips() throws {
        var s = SessionConfig(name: "s", host: "h", username: "u")
        s.onConnectCommands = "cd /srv\nls -la"
        let decoded = try JSONDecoder().decode(SessionConfig.self,
                                               from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.onConnectCommands, "cd /srv\nls -la")
    }
}

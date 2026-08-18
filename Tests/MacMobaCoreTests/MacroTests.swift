import XCTest

@testable import MacMobaCore

final class MacroTests: XCTestCase {
    // A PTY takes CR for Return. Sending LF instead lands the cursor on the
    // next line without submitting, which is how a macro silently does nothing.
    func testKeystrokesUseCarriageReturn() {
        let macro = MacroConfig(name: "two", command: "cd /tmp\nls -la", sendReturn: true)
        XCTAssertEqual(macro.keystrokes, "cd /tmp\rls -la\r")
        XCTAssertFalse(macro.keystrokes.contains("\n"))
    }

    func testCRLFIsNormalised() {
        let macro = MacroConfig(name: "crlf", command: "a\r\nb", sendReturn: false)
        XCTAssertEqual(macro.keystrokes, "a\rb")
    }

    func testSendReturnOffLeavesTextOnThePrompt() {
        let macro = MacroConfig(name: "draft", command: "rm -rf /important", sendReturn: false)
        XCTAssertEqual(macro.keystrokes, "rm -rf /important")
    }

    // A command already ending in a newline should not get a second Return —
    // that would submit an empty line and re-run the last command in some shells.
    func testTrailingNewlineIsNotDoubled() {
        let macro = MacroConfig(name: "trailing", command: "uptime\n", sendReturn: true)
        XCTAssertEqual(macro.keystrokes, "uptime\r")
    }

    func testEmptyCommandProducesNothingToSendWhenReturnIsOff() {
        XCTAssertEqual(MacroConfig(name: "empty", command: "", sendReturn: false).keystrokes, "")
    }

    // MARK: - Vault round-trip

    func testMacrosSurviveVaultRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macro-vault-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let vault = Vault(fileURL: url)
        var data = try vault.create(masterPassword: "hunter2")
        data.macros = [MacroConfig(name: "tail log", command: "tail -f /var/log/syslog")]
        try vault.save(data)

        let reopened = Vault(fileURL: url)
        let loaded = try reopened.unlock(masterPassword: "hunter2")
        XCTAssertEqual(loaded.macros.count, 1)
        XCTAssertEqual(loaded.macros[0].name, "tail log")
        XCTAssertTrue(loaded.macros[0].sendReturn)
    }

    // A vault written before macros existed — and one written by the Electron
    // version, which does not know the key — has no "macros" field at all.
    // Synthesised Codable would throw on the missing key.
    func testVaultDataDecodesWithoutMacrosKey() throws {
        let json = #"{"sessions":[],"tunnels":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(VaultData.self, from: json)
        XCTAssertTrue(decoded.macros.isEmpty)
    }

    func testVaultDataDecodesFromEmptyObject() throws {
        let decoded = try JSONDecoder().decode(VaultData.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(decoded.sessions.isEmpty)
        XCTAssertTrue(decoded.tunnels.isEmpty)
        XCTAssertTrue(decoded.macros.isEmpty)
    }
}

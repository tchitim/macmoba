import XCTest

@testable import MacMobaCore

final class TokenExpanderTests: XCTestCase {
    private func session() -> SessionConfig {
        var s = SessionConfig(id: "s", name: "prod-web", host: "10.0.0.5", port: 2222,
                              username: "deploy", authType: "password")
        s.group = "Production"
        s.domain = "CORP"
        return s
    }

    func testExpandsEachToken() {
        let s = session()
        XCTAssertEqual(TokenExpander.expand("%host%", in: s), "10.0.0.5")
        XCTAssertEqual(TokenExpander.expand("%port%", in: s), "2222")
        XCTAssertEqual(TokenExpander.expand("%username%", in: s), "deploy")
        XCTAssertEqual(TokenExpander.expand("%user%", in: s), "deploy")
        XCTAssertEqual(TokenExpander.expand("%name%", in: s), "prod-web")
        XCTAssertEqual(TokenExpander.expand("%group%", in: s), "Production")
        XCTAssertEqual(TokenExpander.expand("%domain%", in: s), "CORP")
    }

    func testTheTemplateUseCase() {
        let s = session()
        XCTAssertEqual(TokenExpander.expand("ssh-copy-id %username%@%host%", in: s),
                       "ssh-copy-id deploy@10.0.0.5")
        XCTAssertEqual(TokenExpander.expand("echo connected to %name% (%host%:%port%)", in: s),
                       "echo connected to prod-web (10.0.0.5:2222)")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(TokenExpander.expand("%HOST% %Host%", in: session()),
                       "10.0.0.5 10.0.0.5")
    }

    func testUnknownTokensLeftUntouched() {
        XCTAssertEqual(TokenExpander.expand("100%% sure about %mystery%", in: session()),
                       "100%% sure about %mystery%")
    }

    func testLoneOrTrailingPercentSurvives() {
        XCTAssertEqual(TokenExpander.expand("50% done at %host%", in: session()),
                       "50% done at 10.0.0.5")
        XCTAssertEqual(TokenExpander.expand("trailing %", in: session()), "trailing %")
    }

    func testNoPercentIsReturnedUnchanged() {
        XCTAssertEqual(TokenExpander.expand("plain command", in: session()), "plain command")
    }

    func testOptionalOverload() {
        XCTAssertNil(TokenExpander.expand(nil, in: session()))
        XCTAssertEqual(TokenExpander.expand(Optional("%host%"), in: session()), "10.0.0.5")
    }

    func testMissingValuesExpandToEmpty() {
        var s = SessionConfig(name: "n", host: "h", username: "u")
        s.group = nil
        XCTAssertEqual(TokenExpander.expand("[%group%]", in: s), "[]")
    }

    // MARK: - templates model

    func testVaultWithoutTemplatesDecodes() throws {
        let json = #"{"sessions":[],"credentials":[]}"#
        let data = try JSONDecoder().decode(VaultData.self, from: Data(json.utf8))
        XCTAssertEqual(data.templates, [])
    }

    func testTemplatesRoundTrip() throws {
        let tmpl = SessionConfig(id: "t", name: "SSH box", host: "", username: "root")
        let vault = VaultData(templates: [tmpl])
        let decoded = try JSONDecoder().decode(VaultData.self,
                                               from: JSONEncoder().encode(vault))
        XCTAssertEqual(decoded.templates, [tmpl])
    }

    /// Instantiating a template is just a duplicate: fresh id, unique name,
    /// everything else carried over — including a blank host to fill in.
    func testInstantiateGivesFreshIdAndKeepsFields() {
        var tmpl = SessionConfig(id: "t", name: "SSH box", host: "", port: 2222,
                                 username: "root", authType: "password")
        tmpl.onConnectCommands = "echo %host%"
        let made = SessionDuplicate.copy(of: tmpl, existingNames: [])
        XCTAssertNotEqual(made.id, "t")
        XCTAssertEqual(made.port, 2222)
        XCTAssertEqual(made.username, "root")
        XCTAssertEqual(made.onConnectCommands, "echo %host%")
    }
}

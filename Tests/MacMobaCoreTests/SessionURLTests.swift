import XCTest
@testable import MacMobaCore

final class SessionURLTests: XCTestCase {

    func testSSHWithUserAndPort() {
        let s = SessionURL.parse("ssh://deploy@example.com:2222")
        XCTAssertEqual(s?.host, "example.com")
        XCTAssertEqual(s?.port, 2222)
        XCTAssertEqual(s?.username, "deploy")
        XCTAssertEqual(s?.sessionKind, .ssh)
        XCTAssertEqual(s?.name, "deploy@example.com")
    }

    func testDefaultPortPerScheme() {
        XCTAssertEqual(SessionURL.parse("ssh://host")?.port, 22)
        XCTAssertEqual(SessionURL.parse("telnet://host")?.port, 23)
        XCTAssertEqual(SessionURL.parse("rdp://host")?.port, 3389)
        XCTAssertEqual(SessionURL.parse("vnc://host")?.port, 5900)
        XCTAssertEqual(SessionURL.parse("ftp://host")?.port, 21)
    }

    func testSftpMapsToSSH() {
        let s = SessionURL.parse("sftp://user@files.example.com")
        XCTAssertEqual(s?.sessionKind, .ssh)
        XCTAssertEqual(s?.port, 22)
    }

    func testPercentEncodedUserAndPassword() {
        // user "jo@n" and password "p@ss word" percent-encoded.
        let s = SessionURL.parse("ssh://jo%40n:p%40ss%20word@host:22")
        XCTAssertEqual(s?.username, "jo@n")
        XCTAssertEqual(s?.password, "p@ss word")
    }

    func testNoPasswordLeavesItNil() {
        XCTAssertNil(SessionURL.parse("ssh://user@host")?.password)
    }

    func testNameFallsBackToHostWithoutUser() {
        let s = SessionURL.parse("rdp://winbox.corp")
        XCTAssertEqual(s?.name, "winbox.corp")
        XCTAssertEqual(s?.username, "")
    }

    func testRejectsUnknownSchemeAndHostlessURL() {
        XCTAssertNil(SessionURL.parse("https://example.com"))
        XCTAssertNil(SessionURL.parse("ssh://"))
        XCTAssertNil(SessionURL.parse("not a url"))
    }

    func testParsesFromURLValue() {
        let url = URL(string: "vnc://10.0.0.5:5901")!
        let s = SessionURL.parse(url)
        XCTAssertEqual(s?.host, "10.0.0.5")
        XCTAssertEqual(s?.port, 5901)
        XCTAssertEqual(s?.sessionKind, .vnc)
    }

    func testSupportedSchemesListed() {
        let schemes = SessionURL.supportedSchemes
        XCTAssertTrue(schemes.contains("ssh"))
        XCTAssertTrue(schemes.contains("rdp"))
        XCTAssertEqual(schemes, schemes.sorted())
    }
}

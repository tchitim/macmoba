import XCTest
@testable import MacMobaCore

/// A remote desktop never sends its clipboard back — macOS's VNC server does
/// not, and the protocol cannot ask. The same machine's shell session can.
final class RemoteShellMatchTests: XCTestCase {

    private func ssh(_ name: String, host: String) -> SessionConfig {
        var session = SessionConfig(name: name, host: host, username: "u")
        session.kind = SessionKind.ssh.rawValue
        return session
    }

    func testFindsTheShellSessionForTheSameHost() {
        let sessions = [ssh("elsewhere", host: "192.0.2.9"), ssh("the box", host: "192.0.2.5")]
        XCTAssertEqual(RemoteShellMatch.session(forHost: "192.0.2.5", in: sessions)?.name, "the box")
    }

    /// The desktop session and the shell session describe one machine and are
    /// unlikely to share a name, so the host is what matches.
    func testMatchingIgnoresCaseAndSurroundingSpace() {
        let sessions = [ssh("box", host: "Mac-Mini.local")]
        XCTAssertNotNil(RemoteShellMatch.session(forHost: "  mac-mini.LOCAL ", in: sessions))
    }

    func testSessionsThatCannotRunACommandAreNeverChosen() {
        var vnc = SessionConfig(name: "desktop", host: "192.0.2.5", username: "u")
        vnc.kind = SessionKind.vnc.rawValue
        var web = SessionConfig(name: "page", host: "192.0.2.5", username: "")
        web.kind = SessionKind.web.rawValue
        XCTAssertNil(RemoteShellMatch.session(forHost: "192.0.2.5", in: [vnc, web]))
    }

    func testNoMatchIsNotAnError() {
        XCTAssertNil(RemoteShellMatch.session(forHost: "192.0.2.5", in: [ssh("other", host: "192.0.2.6")]))
        XCTAssertNil(RemoteShellMatch.session(forHost: "", in: [ssh("other", host: "")]),
                     "an empty host matches nothing rather than everything")
    }

    func testTheCommandTriesMacOSThenX11() {
        let command = RemoteShellMatch.readClipboardCommand
        XCTAssertTrue(command.hasPrefix("pbpaste"))
        XCTAssertTrue(command.contains("xclip"))
        XCTAssertTrue(command.contains("xsel"))
    }
}

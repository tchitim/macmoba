import XCTest

@testable import MacMobaCore

final class SessionKindTests: XCTestCase {
    // Every session written before VNC/RDP existed has no "kind" at all, and
    // the Electron version never writes one. Those must stay SSH.
    func testMissingKindIsSSH() throws {
        let json = """
        {"id":"a","name":"old","host":"h","port":22,"username":"u","authType":"password"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: json)
        XCTAssertEqual(decoded.sessionKind, .ssh)
    }

    // A kind written by a newer build should degrade to SSH rather than making
    // the whole vault undecodable.
    func testUnknownKindFallsBackToSSH() throws {
        let json = """
        {"id":"a","name":"future","host":"h","port":22,"username":"u",
         "authType":"password","kind":"spice"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: json)
        XCTAssertEqual(decoded.sessionKind, .ssh)
    }

    func testKnownKindsRoundTrip() throws {
        for kind in SessionKind.allCases {
            let config = SessionConfig(name: "s", host: "h", username: "u",
                                       kind: kind == .ssh ? nil : kind.rawValue)
            let data = try JSONEncoder().encode(config)
            let back = try JSONDecoder().decode(SessionConfig.self, from: data)
            XCTAssertEqual(back.sessionKind, kind)
        }
    }

    func testDefaultPorts() {
        XCTAssertEqual(SessionKind.ssh.defaultPort, 22)
        XCTAssertEqual(SessionKind.vnc.defaultPort, 5900)
        XCTAssertEqual(SessionKind.rdp.defaultPort, 3389)
    }

    // Only the remote-desktop kinds need a forwarded TCP port; SSH does its
    // jump-host hop inside the protocol.
    func testOnlyRemoteDesktopKindsTunnel() {
        XCTAssertFalse(SessionKind.ssh.usesPortTunnel)
        XCTAssertTrue(SessionKind.vnc.usesPortTunnel)
        XCTAssertTrue(SessionKind.rdp.usesPortTunnel)
    }

    // A split pane is a terminal. Handing one a VNC or RDP config used to give
    // a pane that opened *SSH* to the remote-desktop port and sat there
    // connecting forever, which looks to the user like a blank pane.
    func testOnlySSHFitsInASplitPane() {
        XCTAssertTrue(SessionKind.ssh.fitsInSplitPane)
        XCTAssertFalse(SessionKind.vnc.fitsInSplitPane)
        XCTAssertFalse(SessionKind.rdp.fitsInSplitPane)
    }

    // A VNC session in the vault must survive a full encrypt/decrypt cycle
    // alongside SSH ones.
    func testMixedKindsSurviveVaultRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kind-vault-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let vault = Vault(fileURL: url)
        var data = try vault.create(masterPassword: "hunter2")
        data.sessions = [
            SessionConfig(id: "1", name: "box", host: "h", username: "u"),
            SessionConfig(id: "2", name: "screen", host: "h", port: 5900,
                          username: "", proxyJump: "1", kind: "vnc"),
        ]
        try vault.save(data)

        let loaded = try Vault(fileURL: url).unlock(masterPassword: "hunter2")
        XCTAssertEqual(loaded.sessions.map(\.sessionKind), [.ssh, .vnc])
        XCTAssertEqual(loaded.sessions[1].proxyJump, "1")
    }
}

extension SessionKindTests {
    /// Mosh starts by running mosh-server over SSH, so it needs everything an
    /// SSH login needs — including a private key. Treating it as "not SSH"
    /// meant a Mosh session could only ever use a password.
    func testMoshAuthenticatesLikeSSH() {
        XCTAssertTrue(SessionKind.ssh.authenticatesOverSSH)
        XCTAssertTrue(SessionKind.mosh.authenticatesOverSSH)
        XCTAssertFalse(SessionKind.telnet.authenticatesOverSSH)
        XCTAssertFalse(SessionKind.vnc.authenticatesOverSSH)
        XCTAssertFalse(SessionKind.rdp.authenticatesOverSSH)
    }

    /// Mosh hops via SSH's own jump, not by forwarding a port — the UDP session
    /// goes straight to the host either way.
    func testOnlySSHLikeKindsUseAJumpHost() {
        XCTAssertTrue(SessionKind.ssh.usesJumpHost)
        XCTAssertTrue(SessionKind.mosh.usesJumpHost)
        XCTAssertFalse(SessionKind.rdp.usesJumpHost)
        XCTAssertFalse(SessionKind.mosh.usesPortTunnel,
                       "Mosh must not be treated as a forwarded TCP port")
    }

    /// Every kind must land in exactly one of the two credential shapes, or the
    /// editor shows a password field twice, or not at all.
    func testEveryKindHasExactlyOneCredentialStyle() {
        for kind in SessionKind.allCases {
            let hasAuthSection = kind.authenticatesOverSSH
            // FTP joins VNC/RDP: a password field beside the username, no
            // Authentication section, because none of the SSH credential
            // types (private key, passphrase, agent) mean anything to it.
            let hasInlinePassword = (kind == .vnc || kind == .rdp || kind == .ftp)
            // Web and Serial join Telnet: nothing to authenticate here. A page
            // asks for its own credentials, a serial line has no login at all,
            // and the SSH session that carries traffic has its own.
            let hasNoCredentials = (kind == .telnet || kind == .web || kind == .serial
                                    || kind == .rlogin)
            XCTAssertEqual([hasAuthSection, hasInlinePassword, hasNoCredentials]
                            .filter { $0 }.count, 1,
                           "\(kind.displayName) does not have exactly one credential style")
        }
    }
}

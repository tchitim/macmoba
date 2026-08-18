// Parser tests for ~/.ssh/config import.

import Foundation
import XCTest

@testable import MacMobaCore

final class SSHConfigImportTests: XCTestCase {
    func testParsesCommonDirectives() {
        let text = """
        # comment
        Host web
            HostName example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519

        Host db
          hostname=10.0.0.5
          user=postgres
        """
        let hosts = SSHConfigImporter.parse(text: text)
        XCTAssertEqual(hosts.count, 2)

        XCTAssertEqual(hosts[0].alias, "web")
        XCTAssertEqual(hosts[0].hostName, "example.com")
        XCTAssertEqual(hosts[0].user, "deploy")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].identityFile?.hasSuffix("/.ssh/id_ed25519"), true)
        XCTAssertFalse(hosts[0].identityFile?.hasPrefix("~") ?? true, "tilde should be expanded")

        // lower-case keywords and `=` separators
        XCTAssertEqual(hosts[1].alias, "db")
        XCTAssertEqual(hosts[1].hostName, "10.0.0.5")
        XCTAssertEqual(hosts[1].user, "postgres")
        XCTAssertNil(hosts[1].port)
    }

    func testSkipsWildcardBlocksAndDefaultsHostName() {
        let text = """
        Host *
            ServerAliveInterval 60

        Host *.internal
            User admin

        Host bare
        """
        let hosts = SSHConfigImporter.parse(text: text)
        // Wildcard blocks are defaults, not connectable hosts.
        XCTAssertEqual(hosts.map(\.alias), ["bare"])
        // A Host with no HostName connects to its own alias.
        XCTAssertEqual(hosts[0].hostName, "bare")
    }

    func testSessionsSkipDuplicatesAndPickAuthType() {
        let hosts = [
            SSHConfigHost(alias: "a", hostName: "a.example", user: "u", port: 22,
                          identityFile: "/keys/id"),
            SSHConfigHost(alias: "b", hostName: "b.example", user: "u", port: 22,
                          identityFile: nil),
        ]
        let existing = [SessionConfig(name: "old", host: "a.example", port: 22, username: "u")]
        let made = SSHConfigImporter.sessions(from: hosts, existing: existing)

        XCTAssertEqual(made.count, 1, "already-known host should be skipped")
        XCTAssertEqual(made[0].host, "b.example")
        XCTAssertEqual(made[0].authType, "password")
        XCTAssertEqual(made[0].group, "SSH Config")

        // With an identity file the session should use key auth.
        let fresh = SSHConfigImporter.sessions(from: hosts, existing: [])
        XCTAssertEqual(fresh.first(where: { $0.host == "a.example" })?.authType, "keyfile")
        XCTAssertEqual(fresh.first(where: { $0.host == "a.example" })?.keyPath, "/keys/id")
    }

    func testMissingUserFallsBackToLocalUser() {
        let hosts = [SSHConfigHost(alias: "x", hostName: "x.example", user: nil, port: nil,
                                   identityFile: nil)]
        let made = SSHConfigImporter.sessions(from: hosts, existing: [])
        XCTAssertEqual(made[0].username, NSUserName())
        XCTAssertEqual(made[0].port, 22)
    }
}

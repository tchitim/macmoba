import XCTest
@testable import MacMobaCore

final class SessionImportTests: XCTestCase {

    // MARK: - OpenSSH config (through the SessionImporter facade)
    //
    // Full ssh_config coverage lives in SSHConfigImportTests; here we prove the
    // facade routes to it and that the newly-added ProxyJump lands on sessions.

    func testSSHConfigThroughFacadeMapsProxyJump() {
        let cfg = """
        Host internal
            HostName 10.0.0.9
            User me
            ProxyJump bastion
        """
        let s = SessionImporter.parse(cfg, as: .sshConfig)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].host, "10.0.0.9")
        XCTAssertEqual(s[0].proxyJump, "bastion")
        XCTAssertEqual(s[0].sessionKind, .ssh)
    }

    func testSSHConfigFacadeDedupsAgainstExisting() {
        let cfg = """
        Host a
            HostName 1.1.1.1
            User u
        Host b
            HostName 2.2.2.2
            User u
        """
        let existing = SessionImporter.parse(cfg, as: .sshConfig)  // both, no filter
        XCTAssertEqual(existing.count, 2)
        // Re-importing with those already present adds nothing.
        let again = SessionImporter.parse(cfg, as: .sshConfig, existing: existing)
        XCTAssertEqual(again.count, 0)
    }

    // MARK: - PuTTY .reg

    func testPuTTYSessions() {
        let reg = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\My%20Server]
        "HostName"="192.168.1.5"
        "PortNumber"=dword:00000016
        "Protocol"="ssh"
        "UserName"="pi"

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\Old%20Router]
        "HostName"="10.0.0.1"
        "PortNumber"=dword:00000017
        "Protocol"="telnet"
        """
        let s = PuTTYImport.parse(reg)
        XCTAssertEqual(s.count, 2)

        let server = s[0]
        XCTAssertEqual(server.name, "My Server")          // %20 decoded
        XCTAssertEqual(server.host, "192.168.1.5")
        XCTAssertEqual(server.port, 22)                    // dword 0x16
        XCTAssertEqual(server.username, "pi")
        XCTAssertEqual(server.sessionKind, .ssh)

        let router = s[1]
        XCTAssertEqual(router.name, "Old Router")
        XCTAssertEqual(router.port, 23)                    // dword 0x17
        XCTAssertEqual(router.sessionKind, .telnet)
    }

    func testPuTTYSkipsUnmappableAndEmptyHost() {
        let reg = """
        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\SerialThing]
        "Protocol"="serial"
        "SerialLine"="COM3"

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\NoHost]
        "Protocol"="ssh"
        """
        let s = PuTTYImport.parse(reg)
        XCTAssertEqual(s.count, 0, "serial (unmapped) and host-less sessions should be dropped")
    }

    // MARK: - RDCMan .rdg

    func testRDGNestedGroupsAndCredentials() {
        let rdg = """
        <?xml version="1.0" encoding="utf-8"?>
        <RDCMan programVersion="2.7" schemaVersion="3">
          <file>
            <properties><name>Root</name></properties>
            <group>
              <properties><name>Production</name></properties>
              <server>
                <properties>
                  <displayName>Web Front End</displayName>
                  <name>10.1.1.10</name>
                </properties>
                <logonCredentials inherit="None">
                  <userName>administrator</userName>
                  <domain>CORP</domain>
                </logonCredentials>
              </server>
              <group>
                <properties><name>Databases</name></properties>
                <server>
                  <properties><name>db01.corp.local</name></properties>
                </server>
              </group>
            </group>
            <server>
              <properties><name>standalone.host</name></properties>
            </server>
          </file>
        </RDCMan>
        """
        let s = RDCManImport.parse(rdg)
        XCTAssertEqual(s.count, 3)

        let web = s.first { $0.host == "10.1.1.10" }
        XCTAssertNotNil(web)
        XCTAssertEqual(web?.name, "Web Front End")
        XCTAssertEqual(web?.username, "administrator")
        XCTAssertEqual(web?.domain, "CORP")
        XCTAssertEqual(web?.sessionKind, .rdp)
        XCTAssertEqual(web?.port, 3389)
        XCTAssertEqual(web?.group, "Production")

        let db = s.first { $0.host == "db01.corp.local" }
        XCTAssertEqual(db?.group, "Production/Databases", "nested group path lost")

        let standalone = s.first { $0.host == "standalone.host" }
        XCTAssertNotNil(standalone)
        XCTAssertNil(standalone?.group, "root-level server should have no group")
    }

    // MARK: - format detection

    func testDetectByExtension() {
        XCTAssertEqual(SessionImporter.detect(filename: "servers.rdg", content: ""), .rdcman)
        XCTAssertEqual(SessionImporter.detect(filename: "putty.reg", content: ""), .putty)
    }

    func testDetectByContent() {
        XCTAssertEqual(SessionImporter.detect(filename: "config", content: "Host foo\n  HostName bar\n"), .sshConfig)
        XCTAssertEqual(SessionImporter.detect(filename: "x.txt", content: "<RDCMan schemaVersion=\"3\">"), .rdcman)
        XCTAssertEqual(SessionImporter.detect(filename: "x.txt",
                       content: "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\A]"), .putty)
        XCTAssertNil(SessionImporter.detect(filename: "random.dat", content: "nothing to see here"))
    }

    func testParseRoutesThroughDetectedFormat() {
        let cfg = "Host h\n  HostName 1.2.3.4\n  User u\n"
        let format = SessionImporter.detect(filename: "config", content: cfg)!
        let s = SessionImporter.parse(cfg, as: format)
        XCTAssertEqual(s.first?.host, "1.2.3.4")
    }
}

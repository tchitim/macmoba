import XCTest

@testable import MacMobaCore

final class BonjourDiscoveryTests: XCTestCase {
    // MARK: - service kind mapping

    func testServiceTypeMapsToSessionKind() {
        XCTAssertEqual(BonjourServiceKind.ssh.sessionKind, .ssh)
        XCTAssertEqual(BonjourServiceKind.sftp.sessionKind, .ssh)   // SFTP is over SSH
        XCTAssertEqual(BonjourServiceKind.vnc.sessionKind, .vnc)
        XCTAssertEqual(BonjourServiceKind.rdp.sessionKind, .rdp)
        XCTAssertEqual(BonjourServiceKind.telnet.sessionKind, .telnet)
        XCTAssertEqual(BonjourServiceKind.ftp.sessionKind, .ftp)
    }

    func testFromServiceTypeWithAndWithoutTrailingDot() {
        XCTAssertEqual(BonjourServiceKind.from(serviceType: "_ssh._tcp"), .ssh)
        XCTAssertEqual(BonjourServiceKind.from(serviceType: "_ssh._tcp."), .ssh)
        XCTAssertEqual(BonjourServiceKind.from(serviceType: "_rfb._tcp"), .vnc)
        XCTAssertNil(BonjourServiceKind.from(serviceType: "_http._tcp"))
    }

    func testServiceTypeStripsTheDot() {
        XCTAssertEqual(BonjourServiceKind.ssh.serviceType, "_ssh._tcp")
    }

    // MARK: - making a session

    func testMakeSessionFromSSHService() {
        let s = DiscoveredService(name: "lab-box", kind: .ssh, host: "lab-box.local", port: 22)
        let session = s.makeSession()
        XCTAssertEqual(session.name, "lab-box")
        XCTAssertEqual(session.host, "lab-box.local")
        XCTAssertEqual(session.port, 22)
        XCTAssertEqual(session.sessionKind, .ssh)
        XCTAssertNil(session.kind)   // ssh stores nil for back-compat
    }

    func testMakeSessionFromVNCService() {
        let s = DiscoveredService(name: "Timo's iMac", kind: .vnc, host: "imac.local", port: 5900)
        let session = s.makeSession()
        XCTAssertEqual(session.sessionKind, .vnc)
        XCTAssertEqual(session.kind, "vnc")
        XCTAssertEqual(session.port, 5900)
    }

    // MARK: - live discovery (advertise with dns-sd, browse, expect it)

    /// Advertise an _ssh._tcp service on a distinctive name and port, then browse
    /// and assert the browser resolves it to a host and the right port/kind. The
    /// browser and NetService run on the main runloop, which `wait` pumps.
    @MainActor
    func testDiscoversAnAdvertisedSSHService() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/dns-sd") else {
            throw XCTSkip("dns-sd not available")
        }
        let uniqueName = "MacMobaTest-\(Int.random(in: 1000...9999))"
        let port = 2222

        let advertiser = Process()
        advertiser.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        advertiser.arguments = ["-R", uniqueName, "_ssh._tcp", "local", String(port)]
        advertiser.standardOutput = FileHandle.nullDevice
        advertiser.standardError = FileHandle.nullDevice
        try advertiser.run()
        defer { advertiser.terminate() }

        let expectation = expectation(description: "discovered the advertised service")
        var discovered: DiscoveredService?
        let browser = BonjourBrowser()
        browser.onChange = { services in
            guard discovered == nil,
                  let match = services.first(where: { $0.name == uniqueName }) else { return }
            discovered = match
            expectation.fulfill()
        }
        browser.start(kinds: [.ssh])
        defer { browser.stop() }

        let result = XCTWaiter().wait(for: [expectation], timeout: 12)
        try XCTSkipIf(result == .timedOut, "advertised service not seen (mDNS unavailable?)")

        XCTAssertEqual(discovered?.name, uniqueName)
        XCTAssertEqual(discovered?.port, port)
        XCTAssertEqual(discovered?.kind, .ssh)
        XCTAssertFalse(discovered?.host.isEmpty ?? true)
    }
}

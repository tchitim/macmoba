import XCTest
@testable import MacMobaCore

final class X11ForwardingTests: XCTestCase {

    // MARK: - display / port math

    func testDisplayToPort() {
        XCTAssertEqual(X11Forwarding.port(forDisplay: 0), 6000)
        XCTAssertEqual(X11Forwarding.port(forDisplay: 10), 6010)
    }

    func testDisplayString() {
        XCTAssertEqual(X11Forwarding.displayString(10), "localhost:10.0")
        XCTAssertEqual(X11Forwarding.displayString(11, screen: 1), "localhost:11.1")
    }

    func testDisplayNumberParsing() {
        XCTAssertEqual(X11Forwarding.displayNumber(from: ":0"), 0)
        XCTAssertEqual(X11Forwarding.displayNumber(from: "localhost:10.0"), 10)
        XCTAssertEqual(X11Forwarding.displayNumber(from: "somehost:11"), 11)
        XCTAssertNil(X11Forwarding.displayNumber(from: "no-colon"))
    }

    // MARK: - tunnel config

    func testRemoteForwardConfig() {
        let cfg = X11Forwarding.remoteForwardConfig(sessionId: "sid", display: 10)
        XCTAssertEqual(cfg.type, "remote")
        XCTAssertEqual(cfg.sessionId, "sid")
        XCTAssertEqual(cfg.bindHost, "127.0.0.1")
        XCTAssertEqual(cfg.bindPort, 6010)          // server listens here
        XCTAssertEqual(cfg.targetHost, "127.0.0.1")
        XCTAssertEqual(cfg.targetPort, 6000)        // local X server
    }

    // MARK: - remote setup commands

    func testRemoteSetupWithoutCookie() {
        let s = X11Forwarding.remoteSetup(display: 10, cookieHex: nil)
        XCTAssertEqual(s, "export DISPLAY=localhost:10.0")
    }

    func testRemoteSetupWithCookie() {
        let s = X11Forwarding.remoteSetup(display: 10, cookieHex: "deadbeef")
        XCTAssertTrue(s.contains("export DISPLAY=localhost:10.0"))
        XCTAssertTrue(s.contains("xauth add localhost:10.0 MIT-MAGIC-COOKIE-1 deadbeef"))
        XCTAssertTrue(s.contains("|| true"), "xauth failure must not abort the session")
    }

    // MARK: - .Xauthority parsing

    func testParsesXauthorityEntry() {
        // One entry: family=256, address="mac", number="0",
        // name="MIT-MAGIC-COOKIE-1", cookie=0x0123456789abcdef0011223344556677
        let cookie: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                               0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]
        let data = xauthEntry(family: 256, address: "mac", number: "0",
                              name: "MIT-MAGIC-COOKIE-1", cookie: cookie)
        let entries = XAuthority.parse(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].family, 256)
        XCTAssertEqual(entries[0].address, "mac")
        XCTAssertEqual(entries[0].displayNumber, "0")
        XCTAssertEqual(entries[0].name, "MIT-MAGIC-COOKIE-1")
        XCTAssertEqual(entries[0].cookieHex, "0123456789abcdef0011223344556677")
    }

    func testCookieLookupPrefersMatchingDisplayThenFallsBack() {
        let c0: [UInt8] = Array(repeating: 0xA0, count: 16)
        let c5: [UInt8] = Array(repeating: 0xB5, count: 16)
        var data = xauthEntry(family: 256, address: "mac", number: "0",
                              name: "MIT-MAGIC-COOKIE-1", cookie: c0)
        data.append(xauthEntry(family: 256, address: "mac", number: "5",
                               name: "MIT-MAGIC-COOKIE-1", cookie: c5))
        let entries = XAuthority.parse(data)
        XCTAssertEqual(XAuthority.cookie(forDisplay: 5, in: entries),
                       String(repeating: "b5", count: 16))
        // No display-99 entry → falls back to the first magic cookie.
        XCTAssertEqual(XAuthority.cookie(forDisplay: 99, in: entries),
                       String(repeating: "a0", count: 16))
    }

    func testParseIgnoresTruncatedTail() {
        var data = xauthEntry(family: 256, address: "mac", number: "0",
                              name: "MIT-MAGIC-COOKIE-1", cookie: Array(repeating: 1, count: 16))
        data.append(contentsOf: [0x01, 0x00, 0x05])   // a bogus half-entry
        XCTAssertEqual(XAuthority.parse(data).count, 1)
    }

    // MARK: - fixture builder

    /// Build one binary Xauthority entry the way the file format lays it out.
    private func xauthEntry(family: UInt16, address: String, number: String,
                            name: String, cookie: [UInt8]) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF)) }
        func field(_ bytes: [UInt8]) { u16(bytes.count); d.append(contentsOf: bytes) }
        u16(Int(family))
        field(Array(address.utf8))
        field(Array(number.utf8))
        field(Array(name.utf8))
        field(cookie)
        return d
    }
}

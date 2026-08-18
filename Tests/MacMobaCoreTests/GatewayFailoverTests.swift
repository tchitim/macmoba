import XCTest

@testable import MacMobaCore

final class GatewayFailoverTests: XCTestCase {
    func testPrimaryOnlyWhenNoFallbacks() {
        let c = GatewayFailover.candidates(primaryHost: "gw", primaryPort: 22, fallbacks: [])
        XCTAssertEqual(c, [.init(host: "gw", port: 22)])
    }

    func testPrimaryFirstThenFallbacks() {
        let c = GatewayFailover.candidates(primaryHost: "gw1", primaryPort: 22,
                                           fallbacks: ["gw2", "gw3:2222"])
        XCTAssertEqual(c, [.init(host: "gw1", port: 22),
                           .init(host: "gw2", port: 22),
                           .init(host: "gw3", port: 2222)])
    }

    func testBareFallbackReusesPrimaryPort() {
        let c = GatewayFailover.candidates(primaryHost: "a", primaryPort: 2200,
                                           fallbacks: ["b"])
        XCTAssertEqual(c.last, .init(host: "b", port: 2200))
    }

    func testExactDuplicatesRemoved() {
        let c = GatewayFailover.candidates(primaryHost: "a", primaryPort: 22,
                                           fallbacks: ["a", "a:22", "b", "b"])
        XCTAssertEqual(c, [.init(host: "a", port: 22), .init(host: "b", port: 22)])
    }

    func testBlanksAndBadPortsSkipped() {
        let c = GatewayFailover.candidates(primaryHost: "a", primaryPort: 22,
                                           fallbacks: ["", "   ", "b:0", "c:99999", "d:notaport"])
        XCTAssertEqual(c, [.init(host: "a", port: 22)])
    }

    func testIPv6InBrackets() {
        XCTAssertEqual(GatewayFailover.parse("[2001:db8::1]", defaultPort: 22),
                       .init(host: "2001:db8::1", port: 22))
        XCTAssertEqual(GatewayFailover.parse("[::1]:2222", defaultPort: 22),
                       .init(host: "::1", port: 2222))
    }

    /// A bare IPv6 literal has several colons — it must not be read as host:port.
    func testBareIPv6NotSplitAsHostPort() {
        XCTAssertEqual(GatewayFailover.parse("2001:db8::1", defaultPort: 22),
                       .init(host: "2001:db8::1", port: 22))
    }
}

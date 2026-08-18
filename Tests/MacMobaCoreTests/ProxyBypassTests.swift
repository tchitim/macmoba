import XCTest

@testable import MacMobaCore

/// These expectations are not guesses: each was measured against a logging
/// SOCKS5 proxy with a real WKWebView before being written down here.
final class ProxyBypassTests: XCTestCase {
    private let home = [ProxyBypass.LocalNetwork(address: "192.0.2.10",
                                                 netmask: "255.255.255.0")]

    /// The case the whole feature exists for: a host behind the bastion is not
    /// on your own network, so it goes through the tunnel.
    func testOffSubnetPrivateAddressIsTunnelled() {
        XCTAssertFalse(ProxyBypass.sendsDirect(host: "10.99.99.99", localNetworks: home))
        XCTAssertFalse(ProxyBypass.sendsDirect(host: "172.20.5.5", localNetworks: home))
        XCTAssertFalse(ProxyBypass.sendsDirect(host: "192.168.1.20", localNetworks: home))
    }

    /// A name is resolved by the proxy, so it tunnels whatever it points at.
    func testHostnamesAreAlwaysTunnelled() {
        XCTAssertFalse(ProxyBypass.sendsDirect(host: "wiki", localNetworks: home))
        XCTAssertFalse(ProxyBypass.sendsDirect(host: "wiki.corp.example",
                                               localNetworks: home))
    }

    func testLoopbackGoesDirect() {
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "127.0.0.1", localNetworks: home))
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "127.0.0.53", localNetworks: home))
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "localhost", localNetworks: home))
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "::1", localNetworks: home))
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "[::1]", localNetworks: home))
    }

    /// The measured surprise: an address on the Mac's own subnet skips the
    /// proxy, so a tab must not claim it went through the tunnel.
    func testOwnSubnetGoesDirect() {
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "192.0.2.10", localNetworks: home))
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "192.0.2.1", localNetworks: home))
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "192.0.2.254", localNetworks: home))
    }

    /// Just outside the mask.
    func testTheSubnetBoundaryIsRespected() {
        XCTAssertFalse(ProxyBypass.sendsDirect(host: "192.0.3.10", localNetworks: home))
        let wide = [ProxyBypass.LocalNetwork(address: "10.0.0.5", netmask: "255.0.0.0")]
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "10.99.99.99", localNetworks: wide))
        XCTAssertFalse(ProxyBypass.sendsDirect(host: "11.0.0.1", localNetworks: wide))
    }

    func testWithNoLocalNetworksOnlyLoopbackIsDirect() {
        XCTAssertTrue(ProxyBypass.sendsDirect(host: "127.0.0.1", localNetworks: []))
        XCTAssertFalse(ProxyBypass.sendsDirect(host: "192.0.2.10", localNetworks: []))
    }

    func testIPv4Parsing() {
        XCTAssertEqual(ProxyBypass.ipv4("0.0.0.0"), 0)
        XCTAssertEqual(ProxyBypass.ipv4("255.255.255.255"), 0xFFFF_FFFF)
        XCTAssertEqual(ProxyBypass.ipv4("1.2.3.4"), 0x0102_0304)
        XCTAssertNil(ProxyBypass.ipv4("1.2.3"))
        XCTAssertNil(ProxyBypass.ipv4("1.2.3.4.5"))
        XCTAssertNil(ProxyBypass.ipv4("1.2.3.256"))
        XCTAssertNil(ProxyBypass.ipv4("1.2.3."))
        XCTAssertNil(ProxyBypass.ipv4("wiki.corp.example.com"))
    }

    /// The real machine has at least a loopback interface, and every entry it
    /// reports must be usable.
    func testLocalNetworksReadsRealInterfaces() {
        let networks = ProxyBypass.localNetworks()
        XCTAssertFalse(networks.isEmpty)
        for network in networks {
            XCTAssertNotNil(ProxyBypass.ipv4(network.address), network.address)
            XCTAssertNotNil(ProxyBypass.ipv4(network.netmask), network.netmask)
        }
    }
}

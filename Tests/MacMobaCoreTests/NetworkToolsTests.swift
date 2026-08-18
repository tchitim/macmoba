import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import MacMobaCore

final class NetworkToolsTests: XCTestCase {

    // MARK: - Wake-on-LAN

    func testMagicPacketStructure() throws {
        let packet = try XCTUnwrap(WakeOnLAN.magicPacket(mac: "01:23:45:67:89:ab"))
        XCTAssertEqual(packet.count, 102)                       // 6 + 16*6
        XCTAssertEqual(Array(packet.prefix(6)), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let mac: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB]
        // Every 6-byte slice after the header is the MAC.
        for rep in 0..<16 {
            let start = 6 + rep * 6
            XCTAssertEqual(Array(packet[start..<start + 6]), mac, "repetition \(rep) wrong")
        }
    }

    func testMagicPacketAcceptsSeparatorVariants() {
        XCTAssertEqual(WakeOnLAN.magicPacket(mac: "0123456789ab"),
                       WakeOnLAN.magicPacket(mac: "01-23-45-67-89-AB"))
        XCTAssertEqual(WakeOnLAN.parseMAC("AA:BB:CC:DD:EE:FF"),
                       [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    func testMagicPacketRejectsBadMAC() {
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "not-a-mac"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "01:23:45:67:89"))     // too short
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "01:23:45:67:89:ab:cd")) // too long
    }

    /// Actually send to loopback and read it back, proving the send path and the
    /// bytes on the wire in one go.
    func testSendReachesALocalUDPSocket() throws {
        let recv = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try XCTSkipUnless(recv >= 0, "no udp socket")
        defer { close(recv) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(recv, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipUnless(bound == 0, "bind failed")
        var name = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(recv, $0, &len) }
        }
        let port = UInt16(bigEndian: name.sin_port)

        try WakeOnLAN.send(mac: "01:23:45:67:89:ab", broadcast: "127.0.0.1", port: port)

        var buf = [UInt8](repeating: 0, count: 256)
        let n = recv_withTimeout(recv, &buf, seconds: 2)
        XCTAssertEqual(n, 102, "did not receive the full magic packet")
        XCTAssertEqual(Array(buf.prefix(6)), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    // MARK: - port scan

    func testScanFindsOnlyTheOpenPort() throws {
        let (fd, openPort) = try makeListener()
        defer { close(fd) }
        // Port 1 is closed; the listener's port is open.
        let result = PortScanner.scan(host: "127.0.0.1", ports: [1, openPort, 2], timeout: 1)
        XCTAssertEqual(result, [openPort])
    }

    func testScanEmptyPortsIsEmpty() {
        XCTAssertEqual(PortScanner.scan(host: "127.0.0.1", ports: []), [])
    }

    // MARK: - DNS

    func testResolvesLocalhost() {
        let ips = DNSLookup.resolve("localhost")
        XCTAssertFalse(ips.isEmpty)
        XCTAssertTrue(ips.contains("127.0.0.1") || ips.contains("::1"),
                      "localhost should resolve to a loopback address, got \(ips)")
    }

    func testResolvesLiteralAddress() {
        XCTAssertEqual(DNSLookup.resolve("127.0.0.1"), ["127.0.0.1"])
    }

    func testUnresolvableIsEmpty() {
        XCTAssertTrue(DNSLookup.resolve("no-such-host.invalid").isEmpty)
    }

    // MARK: - helpers

    private func makeListener() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw Err.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw Err.bind }
        var name = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, Int(UInt16(bigEndian: name.sin_port)))
    }

    private func recv_withTimeout(_ fd: Int32, _ buf: inout [UInt8], seconds: Int) -> Int {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
    }

    private enum Err: Error { case socket, bind }
}

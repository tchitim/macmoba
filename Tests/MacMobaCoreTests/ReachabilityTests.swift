import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import MacMobaCore

final class ReachabilityTests: XCTestCase {

    func testReachesALiveListener() throws {
        let (fd, port) = try makeListener()
        defer { close(fd) }

        let result = ReachabilityProbe.check(host: "127.0.0.1", port: port, timeout: 2)
        guard case .up(let ms) = result else {
            return XCTFail("expected .up for a live listener, got \(result)")
        }
        XCTAssertTrue(result.isUp)
        XCTAssertGreaterThanOrEqual(ms, 0)
        XCTAssertLessThan(ms, 2000, "localhost latency should be tiny")
    }

    func testRefusedPortIsDown() {
        // Nothing listens on port 1; the kernel refuses immediately.
        let result = ReachabilityProbe.check(host: "127.0.0.1", port: 1, timeout: 2)
        XCTAssertFalse(result.isUp)
        if case .down(let reason) = result {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("expected .down for a closed port, got \(result)")
        }
    }

    func testUnresolvableHostIsDown() {
        let result = ReachabilityProbe.check(host: "no-such-host.invalid", port: 22, timeout: 2)
        XCTAssertFalse(result.isUp)
        if case .down(let reason) = result {
            XCTAssertTrue(reason.contains("resolve"), "unhelpful reason: \(reason)")
        } else {
            XCTFail("expected .down for an unresolvable host, got \(result)")
        }
    }

    func testUnroutableAddressTimesOutAsDown() {
        // 192.0.2.0/24 is TEST-NET-1 (RFC 5737): guaranteed not routed, so the
        // handshake never completes. Either a timeout or "no route" is fine —
        // the point is it does not hang and reports down.
        let start = Date()
        let result = ReachabilityProbe.check(host: "192.0.2.1", port: 80, timeout: 1)
        XCTAssertFalse(result.isUp)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0, "probe ignored its timeout")
    }

    // MARK: - which sessions are checkable

    func testReachabilityTargetSkipsSerialAndWeb() {
        var serial = SessionConfig(name: "s", host: "/dev/cu.usb", username: "")
        serial.kind = SessionKind.serial.rawValue
        XCTAssertNil(serial.reachabilityTarget)

        var web = SessionConfig(name: "w", host: "example.com", username: "")
        web.kind = SessionKind.web.rawValue
        XCTAssertNil(web.reachabilityTarget)
    }

    func testReachabilityTargetForNetworkSessions() {
        var ssh = SessionConfig(name: "h", host: "10.0.0.1", port: 2222, username: "u")
        ssh.kind = SessionKind.ssh.rawValue
        let t = ssh.reachabilityTarget
        XCTAssertEqual(t?.host, "10.0.0.1")
        XCTAssertEqual(t?.port, 2222)

        var rdp = SessionConfig(name: "r", host: "", port: 3389, username: "u")
        rdp.kind = SessionKind.rdp.rawValue
        XCTAssertNil(rdp.reachabilityTarget, "empty host is not checkable")
    }

    // MARK: - helpers

    /// A listening TCP socket on 127.0.0.1 with a kernel-chosen port.
    private func makeListener() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw Err.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0   // let the kernel choose
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw Err.bind }
        guard listen(fd, 4) == 0 else { close(fd); throw Err.listen }

        var name = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard got == 0 else { close(fd); throw Err.sockname }
        return (fd, Int(UInt16(bigEndian: name.sin_port)))
    }

    private enum Err: Error { case socket, bind, listen, sockname }
}

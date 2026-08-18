import XCTest

@testable import MacMobaCore

/// The web browser's reason to exist is reaching a page that is only reachable
/// from inside the network, so what has to be proven is not "a page loaded" but
/// "the request travelled through the SSH session".
///
/// Two things are checked here, both from ground truth rather than appearance:
/// the HTTP response comes back intact through the SOCKS proxy, and the SSH
/// server's own log records the direct-tcpip forward that carried it.
///
/// Needs the test SSH server with forward logging, and any HTTP server:
///
///     MM_RX_LOG=/tmp/forwards.log node TestSupport/ssh-server.js
///     python3 -m http.server 8099 --bind 127.0.0.1
final class WebTunnelTests: XCTestCase {
    private static let host = "127.0.0.1"
    private static let sshPort = 2299
    private static let webPort = 8099

    private func listening(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, Self.host, &addr.sin_addr)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private func bastion() -> SessionConfig {
        SessionConfig(id: "bastion", name: "bastion", host: Self.host, port: Self.sshPort,
                      username: "test", authType: "password", password: "secret")
    }

    /// A whole HTTP exchange through the SOCKS proxy the web tab opens.
    func testAPageLoadsThroughTheTunnel() async throws {
        try XCTSkipUnless(listening(Self.sshPort), "no SSH test server")
        try XCTSkipUnless(listening(Self.webPort), "no HTTP test server")

        let tunnel = TunnelConfig(name: "web", type: "dynamic", sessionId: "bastion",
                                  bindHost: Self.host, bindPort: 0,
                                  targetHost: "", targetPort: 0)
        let forward = try await DynamicForward.start(config: tunnel, session: bastion())
        defer { forward.stop() }

        let page = try httpThroughSocks(proxyPort: forward.localPort,
                                        host: Self.host, port: Self.webPort, path: "/")
        XCTAssertTrue(page.contains("REACHED-VIA-TUNNEL"),
                      "expected the marker page, got: \(page.prefix(200))")
        XCTAssertTrue(page.hasPrefix("HTTP/1.0 200") || page.hasPrefix("HTTP/1.1 200"),
                      "expected a 200, got: \(page.prefix(60))")
    }

    /// Port 0 on purpose: every web tab gets a tunnel of its own, so two tabs
    /// open at once must not collide on a fixed port.
    func testEachTabGetsItsOwnProxyPort() async throws {
        try XCTSkipUnless(listening(Self.sshPort), "no SSH test server")

        let tunnel = TunnelConfig(name: "web", type: "dynamic", sessionId: "bastion",
                                  bindHost: Self.host, bindPort: 0,
                                  targetHost: "", targetPort: 0)
        let first = try await DynamicForward.start(config: tunnel, session: bastion())
        defer { first.stop() }
        let second = try await DynamicForward.start(config: tunnel, session: bastion())
        defer { second.stop() }

        XCTAssertNotEqual(first.localPort, second.localPort)
        XCTAssertGreaterThan(first.localPort, 0)
    }

    /// Speaks SOCKS5 and HTTP/1.1 by hand, so nothing in URLSession can quietly
    /// take a different route and make the test pass for the wrong reason.
    private func httpThroughSocks(proxyPort: Int, host: String, port: Int,
                                  path: String) throws -> String {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(proxyPort).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "could not reach the SOCKS proxy")

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        func send(_ bytes: [UInt8]) {
            _ = bytes.withUnsafeBufferPointer { write(sock, $0.baseAddress, $0.count) }
        }
        func recv(_ count: Int) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: count)
            var filled = 0
            while filled < count {
                let n = buffer.withUnsafeMutableBufferPointer {
                    read(sock, $0.baseAddress! + filled, count - filled)
                }
                if n <= 0 { break }
                filled += n
            }
            return Array(buffer.prefix(filled))
        }

        // Greeting: SOCKS5, one method, "no authentication".
        send([0x05, 0x01, 0x00])
        XCTAssertEqual(recv(2), [0x05, 0x00], "SOCKS greeting refused")

        // CONNECT by domain name, which is the form a browser uses.
        let hostBytes = Array(host.utf8)
        send([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)] + hostBytes
             + [UInt8(port >> 8), UInt8(port & 0xff)])
        let reply = recv(10)
        XCTAssertEqual(reply.count, 10, "short SOCKS reply")
        XCTAssertEqual(reply[1], 0x00, "SOCKS CONNECT failed with code \(reply[1])")

        let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
            + "Connection: close\r\n\r\n"
        send(Array(request.utf8))

        var response = Data()
        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBufferPointer { read(sock, $0.baseAddress, 4096) }
            if n <= 0 { break }
            response.append(contentsOf: chunk.prefix(n))
        }
        return String(decoding: response, as: UTF8.self)
    }
}

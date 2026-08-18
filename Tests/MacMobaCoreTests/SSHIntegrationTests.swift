// Integration tests against a real SSH server (TestSupport/ssh-server.js,
// port 2299, user "test" / password "secret").
// If nothing is listening on 2299 the tests are skipped, so `swift test`
// still passes on machines without node. To run the full suite:
//   node TestSupport/ssh-server.js &   (needs `npm install` in TestSupport)
//   swift test

import Foundation
import NIOCore
import NIOPosix
import XCTest

@testable import MacMobaCore

final class SSHIntegrationTests: XCTestCase {
    static let host = "127.0.0.1"
    static let port = 2299

    private func serverAvailable() -> Bool {
        #if canImport(Darwin)
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(Self.port).bigEndian
        inet_pton(AF_INET, Self.host, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func testSession(password: String = "secret") -> SessionConfig {
        SessionConfig(
            name: "test", host: Self.host, port: Self.port,
            username: "test", authType: "password", password: password
        )
    }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var exitReason: String?

        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        func exit(_ why: String) { lock.lock(); exitReason = why; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
        var exited: String? { lock.lock(); defer { lock.unlock() }; return exitReason }
    }

    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func testShellConnectEchoResizeDisconnect() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let collector = Collector()
        let conn = try await SSHConnection.connect(
            config: testSession(), cols: 80, rows: 24,
            onData: { collector.append($0) },
            onExit: { collector.exit($0) }
        )

        waitUntil(3) { collector.text.contains("Welcome to smoke-server") }
        XCTAssertTrue(collector.text.contains("Welcome to smoke-server"), "banner: \(collector.text)")

        conn.write(Data("hello-from-swift\n".utf8))
        waitUntil(3) { collector.text.contains("hello-from-swift") }
        XCTAssertTrue(collector.text.contains("hello-from-swift"), "echo: \(collector.text)")

        conn.resize(cols: 120, rows: 40) // must not throw/crash

        conn.close()
        waitUntil(3) { collector.exited != nil }
        XCTAssertNotNil(collector.exited)
    }

    func testBadPasswordRejected() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        do {
            _ = try await SSHConnection.connect(
                config: testSession(password: "wrong"),
                onData: { _ in }, onExit: { _ in }
            )
            XCTFail("connection with bad password must fail")
        } catch {
            // expected
        }
    }

    func testLocalTunnelEndToEnd() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")

        // 1. local TCP echo service (the tunnel target)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let echoServer = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { ch in ch.pipeline.addHandler(EchoHandler()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let echoPort = echoServer.localAddress!.port!
        defer { try? echoServer.close().wait() }

        // 2. tunnel: 127.0.0.1:<bind> --ssh--> 127.0.0.1:<echoPort>
        let tunnelCfg = TunnelConfig(
            name: "t", type: "local", sessionId: "x",
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: "127.0.0.1", targetPort: echoPort
        )
        let forward = try await LocalForward.start(config: tunnelCfg, session: testSession())
        defer { forward.stop() }
        let bindPort = forward.localPort

        // 3. connect through the tunnel and verify the echo round-trip
        let reply = try await tcpRoundTrip(
            group: group, host: "127.0.0.1", port: bindPort, send: "ping-through-tunnel")
        XCTAssertEqual(reply, "TCPECHO:ping-through-tunnel")
    }

    func testRemoteTunnelEndToEnd() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")

        // 1. local TCP echo service (the -R target on our side)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let echoServer = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { ch in ch.pipeline.addHandler(EchoHandler()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let echoPort = echoServer.localAddress!.port!
        defer { try? echoServer.close().wait() }

        // 2. -R: server listens on 28299 → forwarded back to our echo service
        let tunnelCfg = TunnelConfig(
            name: "r", type: "remote", sessionId: "x",
            bindHost: "127.0.0.1", bindPort: 28299,
            targetHost: "127.0.0.1", targetPort: echoPort
        )
        let forward = try await RemoteForward.start(config: tunnelCfg, session: testSession())
        defer { forward.stop() }
        XCTAssertEqual(forward.boundPort, 28299)

        // 3. connect to the server-side listener; traffic must round-trip
        //    through SSH back to the local echo service.
        let reply = try await tcpRoundTrip(
            group: group, host: "127.0.0.1", port: 28299, send: "ping-back-through-R")
        XCTAssertEqual(reply, "TCPECHO:ping-back-through-R")
    }

    func testProxyJumpReachesTargetThroughBastion() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")

        // The test server speaks both SSH and direct-tcpip, so it can act as
        // its own bastion: connect to it, then tunnel a second SSH session
        // through it back to itself.
        let collector = Collector()
        let conn = try await SSHConnection.connect(
            config: testSession(),
            jumps: [testSession()],
            onData: { collector.append($0) },
            onExit: { collector.exit($0) }
        )
        defer { conn.close() }

        waitUntil(10) { collector.text.contains("Welcome to smoke-server") }
        XCTAssertTrue(collector.text.contains("Welcome to smoke-server"),
                      "target shell never came up through the jump host")

        // Prove the tunnelled session is really interactive, not just connected.
        conn.write(Data("hello-via-jump\n".utf8))
        waitUntil(5) { collector.text.contains("hello-via-jump") }
        XCTAssertTrue(collector.text.contains("hello-via-jump"))
    }

    func testDynamicForwardSocks5() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")

        // Echo service that the SOCKS client will reach *through* the tunnel.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let echoServer = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { ch in ch.pipeline.addHandler(EchoHandler()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let echoPort = echoServer.localAddress!.port!
        defer { try? echoServer.close().wait() }

        let cfg = TunnelConfig(
            name: "d", type: "dynamic", sessionId: "x",
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: "", targetPort: 0
        )
        let forward = try await DynamicForward.start(config: cfg, session: testSession())
        defer { forward.stop() }

        // Speak SOCKS5 by hand: greeting, CONNECT by domain name, then data.
        let reply = try socksRoundTrip(proxyPort: forward.localPort,
                                       host: "localhost", port: echoPort,
                                       send: "ping-through-socks")
        XCTAssertEqual(reply, "TCPECHO:ping-through-socks")
    }

    /// Minimal blocking SOCKS5 client used by the test above.
    private func socksRoundTrip(proxyPort: Int, host: String, port: Int,
                                send: String) throws -> String {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(proxyPort).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "could not reach the SOCKS proxy")

        func push(_ bytes: [UInt8]) {
            _ = bytes.withUnsafeBytes { write(sock, $0.baseAddress, $0.count) }
        }
        func recv(_ count: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: count)
            let n = read(sock, &out, count)
            return n > 0 ? Array(out[0..<n]) : []
        }

        // greeting: VER=5, 1 method, no-auth
        push([5, 1, 0])
        let greeting = recv(2)
        XCTAssertEqual(greeting, [5, 0], "proxy did not accept no-auth")

        // CONNECT by domain
        var request: [UInt8] = [5, 1, 0, 3, UInt8(host.utf8.count)]
        request += Array(host.utf8)
        request += [UInt8(port >> 8), UInt8(port & 0xff)]
        push(request)
        let response = recv(10)
        XCTAssertEqual(response.first, 5)
        XCTAssertEqual(response.dropFirst().first, 0, "SOCKS CONNECT failed")

        push(Array(send.utf8))
        Thread.sleep(forTimeInterval: 0.4)
        return String(decoding: recv(256), as: UTF8.self)
    }

    // MARK: - helpers

    final class EchoHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buf = unwrapInboundIn(data)
            let s = buf.readString(length: buf.readableBytes) ?? ""
            var out = context.channel.allocator.buffer(capacity: s.count + 8)
            out.writeString("TCPECHO:" + s)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
    }

    final class ReplyHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let promise: EventLoopPromise<String>
        let expectedLength: Int
        private var received = ""
        init(promise: EventLoopPromise<String>, expectedLength: Int) {
            self.promise = promise
            self.expectedLength = expectedLength
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buf = unwrapInboundIn(data)
            received += buf.readString(length: buf.readableBytes) ?? ""
            if received.count >= expectedLength {
                promise.succeed(received)
                context.close(promise: nil)
            }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            promise.fail(error)
            context.close(promise: nil)
        }
    }

    private func tcpRoundTrip(group: EventLoopGroup, host: String, port: Int, send: String) async throws -> String {
        let promise = group.next().makePromise(of: String.self)
        let expected = "TCPECHO:".count + send.count
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { ch in
                ch.pipeline.addHandler(ReplyHandler(promise: promise, expectedLength: expected))
            }
            .connect(host: host, port: port).get()
        var buf = channel.allocator.buffer(capacity: send.count)
        buf.writeString(send)
        try await channel.writeAndFlush(buf).get()
        let timeoutTask = group.next().scheduleTask(in: .seconds(5)) {
            promise.fail(SSHError.timeout("tunnel round trip"))
        }
        defer { timeoutTask.cancel() }
        return try await promise.futureResult.get()
    }
}

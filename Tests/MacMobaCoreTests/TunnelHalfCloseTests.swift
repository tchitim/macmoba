import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

@testable import MacMobaCore

/// The bug this guards against made a whole web app crawl.
///
/// Both ends of a forwarded connection run with `allowRemoteHalfClosure`, so
/// when the far side stops sending, NIO reports `inputClosed` instead of firing
/// `channelInactive`. The glue handler ignored that event, so the EOF was never
/// passed on. Anything that ends a response by closing rather than by
/// Content-Length — a streaming endpoint, `Connection: close`, or a server
/// retiring an idle keep-alive connection — simply never finished. Measured
/// against the same server: direct worked, `ssh -D` worked, ours hung.
///
/// The integration test below only has teeth when the test SSH server is in
/// EOF-only mode, because ssh2 normally follows CHANNEL_EOF with CHANNEL_CLOSE
/// straight away, and the close alone was enough to unblock the old code:
///
///     MM_EOF_ONLY=1 node TestSupport/ssh-server.js
///
/// Measured: old code failed after the full 8s socket timeout, new code passed
/// in 21ms. `testEOFOnOneSideClosesTheOthersOutput` covers the same mechanism
/// deterministically, with no server at all.
final class TunnelHalfCloseTests: XCTestCase {
    private static let sshPort = 2299

    private func sshServerIsUp() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(Self.sshPort).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    /// Records how the channel below it was closed.
    private final class CloseRecorder: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        var closedModes: [CloseMode] = []

        func close(context: ChannelHandlerContext, mode: CloseMode,
                   promise: EventLoopPromise<Void>?) {
            closedModes.append(mode)
            context.close(mode: mode, promise: promise)
        }
    }

    /// The mechanism itself: an EOF on one side must close the other side's
    /// write end — and only the write end, because the other direction may
    /// still be carrying data.
    func testEOFOnOneSideClosesTheOthersOutput() throws {
        let (left, right) = GlueHandler.matchedPair()
        let recorder = CloseRecorder()
        let leftChannel = EmbeddedChannel()
        let rightChannel = EmbeddedChannel()
        try leftChannel.pipeline.syncOperations.addHandler(left)
        try rightChannel.pipeline.syncOperations.addHandler(recorder)
        try rightChannel.pipeline.syncOperations.addHandler(right)

        XCTAssertEqual(recorder.closedModes, [], "nothing closed yet")
        leftChannel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        leftChannel.embeddedEventLoop.run()
        rightChannel.embeddedEventLoop.run()

        // EmbeddedChannel does not implement half-closure, so the documented
        // fallback (a full close) follows — which is the point of having one.
        XCTAssertEqual(recorder.closedModes.first, .output,
                       "an EOF on one side must first half-close the other")
        XCTAssertFalse(recorder.closedModes.isEmpty)
    }

    /// Answers every request with a body that ends at EOF — no Content-Length.
    private final class EOFResponder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                + "Connection: close\r\n\r\nBODY-ENDS-AT-EOF\n"
            var buffer = context.channel.allocator.buffer(capacity: response.utf8.count)
            buffer.writeString(response)
            context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
                // The EOF IS the end of the body.
                context.close(mode: .output, promise: nil)
            }
        }
    }

    func testAResponseThatEndsAtEOFCompletes() async throws {
        try XCTSkipUnless(sshServerIsUp(), "no SSH test server on 127.0.0.1:2299")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let origin = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET),
                                                       SO_REUSEADDR), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(EOFResponder()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = origin.localAddress!.port!
        defer { try? origin.close().wait() }

        let session = SessionConfig(id: "h", name: "h", host: "127.0.0.1", port: Self.sshPort,
                                    username: "test", authType: "password", password: "secret")
        let tunnel = TunnelConfig(name: "half", type: "dynamic", sessionId: "h",
                                  bindHost: "127.0.0.1", bindPort: 0,
                                  targetHost: "", targetPort: 0)
        let forward = try await DynamicForward.start(config: tunnel, session: session)
        defer { forward.stop() }

        let started = Date()
        let response = try request(proxyPort: forward.localPort, host: "127.0.0.1",
                                   port: originPort)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(response.contains("BODY-ENDS-AT-EOF"),
                      "body never arrived: \(response.prefix(120))")
        // With the EOF swallowed this only returned when the socket timed out.
        XCTAssertLessThan(elapsed, 3.0,
                          "the read only ended on timeout — EOF was not passed on")
    }

    /// Reads until EOF, exactly as a client waiting for the end of a body does.
    private func request(proxyPort: Int, host: String, port: Int) throws -> String {
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
        // Bounds how long a swallowed EOF can hang this test.
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        func send(_ bytes: [UInt8]) {
            _ = bytes.withUnsafeBufferPointer { write(sock, $0.baseAddress, $0.count) }
        }
        send([0x05, 0x01, 0x00])
        var greeting = [UInt8](repeating: 0, count: 2)
        _ = greeting.withUnsafeMutableBufferPointer { read(sock, $0.baseAddress, 2) }
        XCTAssertEqual(greeting, [0x05, 0x00])

        let hostBytes = Array(host.utf8)
        send([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)] + hostBytes
             + [UInt8(port >> 8), UInt8(port & 0xff)])
        var reply = [UInt8](repeating: 0, count: 10)
        _ = reply.withUnsafeMutableBufferPointer { read(sock, $0.baseAddress, 10) }
        XCTAssertEqual(reply[1], 0x00, "SOCKS CONNECT failed")

        send(Array("GET / HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8))

        var data = Data()
        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBufferPointer { read(sock, $0.baseAddress, 4096) }
            if n <= 0 { break }
            data.append(contentsOf: chunk.prefix(n))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

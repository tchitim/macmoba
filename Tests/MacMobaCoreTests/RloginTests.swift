import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import MacMobaCore

final class RloginTests: XCTestCase {

    // MARK: - protocol bytes

    func testConnectStringLayout() {
        let bytes = RloginProtocol.connectString(localUser: "jo", remoteUser: "root",
                                                 termType: "xterm", speed: 38400)
        // \0 jo \0 root \0 xterm/38400 \0
        let expected: [UInt8] = [0x00]
            + Array("jo".utf8) + [0x00]
            + Array("root".utf8) + [0x00]
            + Array("xterm/38400".utf8) + [0x00]
        XCTAssertEqual(bytes, expected)
    }

    func testWindowSizeMessage() {
        let msg = RloginProtocol.windowSizeMessage(cols: 80, rows: 24)
        XCTAssertEqual(Array(msg.prefix(4)), [0xFF, 0xFF, 0x73, 0x73])  // magic + "ss"
        // rows=24, cols=80, 0, 0 — each big-endian uint16.
        XCTAssertEqual(Array(msg.suffix(8)), [0, 24, 0, 80, 0, 0, 0, 0])
    }

    func testInterpretReplyAccepted() {
        let reply: [UInt8] = [0x00] + Array("welcome\r\n".utf8)
        XCTAssertEqual(RloginProtocol.interpretReply(reply),
                       .accepted(data: Array("welcome\r\n".utf8)))
    }

    func testInterpretReplyRejected() {
        let reply = Array("\u{01}permission denied\r\n".utf8)
        guard case .rejected(let message) = RloginProtocol.interpretReply(reply) else {
            return XCTFail("expected rejection")
        }
        XCTAssertTrue(message.contains("permission denied"))
    }

    func testInterpretEmptyReply() {
        XCTAssertEqual(RloginProtocol.interpretReply([]), .accepted(data: []))
    }

    // MARK: - integration against an in-process rlogin server

    func testHandshakeAndStreamOverTCP() throws {
        let server = try MockRloginServer()
        server.start()
        defer { server.stop() }

        let received = Received()
        let exited = XCTestExpectation(description: "onExit")
        let config = SessionConfig(name: "r", host: "127.0.0.1", port: server.port,
                                   username: "root")
        let conn = try runAsync {
            try await RloginConnection.connect(
                config: config, localUser: "localjo",
                onData: { received.append($0) },
                onExit: { _ in exited.fulfill() })
        }
        defer { conn.close() }

        // The server records the handshake it received and replies 0x00 + banner.
        wait(until: { server.handshake != nil }, timeout: 3)
        let handshake = try XCTUnwrap(server.handshake)
        // localUser, remoteUser and a term/speed field are all present.
        XCTAssertTrue(handshake.contains(0x00))
        let text = String(decoding: handshake, as: UTF8.self)
        XCTAssertTrue(text.contains("localjo"), "local user missing: \(text)")
        XCTAssertTrue(text.contains("root"), "remote user missing: \(text)")

        wait(until: { received.text.contains("MOTD") }, timeout: 3)
        XCTAssertTrue(received.text.contains("MOTD"),
                      "did not receive banner after ack, got: \(received.text)")

        // Pane -> server: what we type reaches the server raw.
        conn.write(Data("whoami\n".utf8))
        wait(until: { server.streamText.contains("whoami") }, timeout: 3)
        XCTAssertTrue(server.streamText.contains("whoami"))
    }

    // MARK: - helpers

    private final class Received: @unchecked Sendable {
        private let lock = NSLock(); private var buf = Data()
        func append(_ d: Data) { lock.lock(); buf.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buf, as: UTF8.self) }
    }

    private func runAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { await box.run(body); sem.signal() }
        sem.wait()
        return try box.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private var result: Result<T, Error>?
        func run(_ body: () async throws -> T) async {
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        func get() throws -> T { try result!.get() }
    }

    private func wait(until cond: @escaping () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if cond() { return }; Thread.sleep(forTimeInterval: 0.02) }
    }
}

/// A minimal rlogin server on a background thread: accept one client, read the
/// handshake, ack with 0x00 + a banner, then record whatever the client sends.
private final class MockRloginServer: @unchecked Sendable {
    let port: Int
    private let listenFd: Int32
    private var clientFd: Int32 = -1
    private let lock = NSLock()
    private var _handshake: Data?
    private var _stream = Data()
    private var stopped = false

    var handshake: Data? { lock.lock(); defer { lock.unlock() }; return _handshake }
    var streamText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: _stream, as: UTF8.self) }

    init() throws {
        // Use a local fd inside the pointer closures — referencing the stored
        // property there would count as capturing self before init completes.
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
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw Err.bind }
        var name = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenFd = fd
        port = Int(UInt16(bigEndian: name.sin_port))
    }

    /// Launched here rather than in init: an escaping closure may not capture
    /// self before initialization completes.
    func start() {
        Thread.detachNewThread { [self] in serve() }
    }

    private func serve() {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { return }
        lock.lock(); clientFd = fd; lock.unlock()

        var buf = [UInt8](repeating: 0, count: 1024)
        // First read is the handshake.
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            lock.lock(); _handshake = Data(buf[0..<n]); lock.unlock()
        }
        // Ack + banner.
        var reply: [UInt8] = [0x00] + Array("MOTD: welcome\r\n".utf8)
        _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // Record anything else the client sends.
        while !stopped {
            let m = read(fd, &buf, buf.count)
            if m <= 0 { break }
            lock.lock(); _stream.append(contentsOf: buf[0..<m]); lock.unlock()
        }
    }

    func stop() {
        stopped = true
        lock.lock(); let c = clientFd; lock.unlock()
        if c >= 0 { close(c) }
        close(listenFd)
    }

    enum Err: Error { case socket, bind }
}

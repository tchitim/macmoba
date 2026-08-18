import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import MacMobaCore

/// The control socket, exercised end to end: a real Unix socket, raw client
/// writes, token checks, malformed input, and multiple requests down one
/// connection — everything the `macmoba` CLI depends on.
final class ControlChannelTests: XCTestCase {

    private var server: ControlServer!
    private var socketPath: String!

    override func setUp() async throws {
        socketPath = NSTemporaryDirectory() + "mm-ctl-\(UUID().uuidString.prefix(8)).sock"
        server = try await ControlServer.start(socketPath: socketPath,
                                               token: "sekrit") { request in
            switch request.cmd {
            case "echo":
                return .success(json: ControlProtocol.encode(request.args))
            case "boom":
                return .failure("deliberate")
            default:
                return .failure("unknown")
            }
        }
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    // MARK: - protocol round-trips

    func testEncodeDecodeRequest() {
        let line = ControlProtocol.encode(
            ControlRequest(token: "t", cmd: "send", args: ["text": "ls\n"]))
        let back = ControlProtocol.decodeRequest(line)
        XCTAssertEqual(back?.cmd, "send")
        XCTAssertEqual(back?.args["text"], "ls\n")
    }

    // MARK: - live socket

    func testRoundTripWithGoodToken() throws {
        let reply = try exchange(#"{"token":"sekrit","cmd":"echo","args":{"k":"v"}}"#)
        XCTAssertTrue(reply.contains("\"ok\":true"), reply)
        XCTAssertTrue(reply.contains("\\\"k\\\":\\\"v\\\"") || reply.contains("k"), reply)
    }

    func testBadTokenIsRefused() throws {
        let reply = try exchange(#"{"token":"WRONG","cmd":"echo","args":{}}"#)
        XCTAssertTrue(reply.contains("\"ok\":false"), reply)
        XCTAssertTrue(reply.contains("bad token"), reply)
    }

    func testMalformedJSONGetsAnErrorNotAHang() throws {
        let reply = try exchange("this is not json")
        XCTAssertTrue(reply.contains("\"ok\":false"), reply)
        XCTAssertTrue(reply.contains("malformed"), reply)
    }

    func testHandlerFailureIsReported() throws {
        let reply = try exchange(#"{"token":"sekrit","cmd":"boom","args":{}}"#)
        XCTAssertTrue(reply.contains("deliberate"), reply)
    }

    func testTwoRequestsOnOneConnection() throws {
        let fd = try connect()
        defer { close(fd) }
        let first = try request(#"{"token":"sekrit","cmd":"echo","args":{"n":"1"}}"#, on: fd)
        let second = try request(#"{"token":"sekrit","cmd":"echo","args":{"n":"2"}}"#, on: fd)
        XCTAssertTrue(first.contains("1"), first)
        XCTAssertTrue(second.contains("2"), second)
    }

    func testStopRemovesTheSocketFile() {
        server.stop()
        // Give the close a beat.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        server = nil
    }

    // MARK: - raw client (what the CLI does)

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                strcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), src)
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw Err.connect }
        return fd
    }

    private func request(_ line: String, on fd: Int32) throws -> String {
        let payload = line + "\n"
        _ = payload.withCString { write(fd, $0, strlen($0)) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while !out.contains(0x0A) {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { throw Err.read }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out.prefix(while: { $0 != 0x0A }), as: UTF8.self)
    }

    private func exchange(_ line: String) throws -> String {
        let fd = try connect()
        defer { close(fd) }
        return try request(line, on: fd)
    }

    private enum Err: Error { case connect, read }
}

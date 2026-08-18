import XCTest
@testable import MacMobaCore

/// End-to-end against TestSupport/telnet-server.js: a real socket, real
/// negotiation, real bytes. The unit tests prove the state machine; these prove
/// it is wired to something.
///
/// Skipped when the server is not running (see TestSupport/telnet-server.js).
final class TelnetIntegrationTests: XCTestCase {

    private let host = "127.0.0.1"
    private let port = 2323
    private let eventLog = "/tmp/macmoba-telnet-events.log"

    private func config() -> SessionConfig {
        SessionConfig(name: "telnet-test", host: host, port: port,
                      username: "", kind: "telnet")
    }

    private func requireServer() throws {
        // Probe the port rather than look for the log file. The log outlives the
        // server, so testing for the file means a stale one from a previous
        // session sends these tests at nothing — which shows up as intermittent
        // failures that look like flakiness in the client.
        guard portIsListening() else {
            throw XCTSkip("telnet test server not running: node TestSupport/telnet-server.js")
        }
        // The server appends to one log for its whole lifetime, so without
        // clearing it here a test can pass on a *previous* test's entries —
        // which is exactly how a broken terminal-type exchange first looked
        // like it was working.
        try? Data().write(to: URL(fileURLWithPath: eventLog))
    }

    /// Collects output until `predicate` is satisfied or time runs out.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        func append(_ data: Data) {
            lock.lock(); bytes += [UInt8](data); lock.unlock()
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func waitFor(timeout: TimeInterval = 10,
                         _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func serverLog() -> String {
        (try? String(contentsOfFile: eventLog, encoding: .utf8)) ?? ""
    }

    /// A plain TCP connect: the only reliable evidence that something is
    /// actually accepting connections on that port right now.
    private func portIsListening() -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { Darwin.close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func testConnectsAndReceivesTheBanner() async throws {
        try requireServer()
        let collector = Collector()
        let connection = try await TelnetConnection.connect(
            config: config(), cols: 100, rows: 30,
            onData: { collector.append($0) },
            onExit: { _ in })
        defer { connection.close() }

        XCTAssertTrue(waitFor { collector.text.contains("MacMoba telnet test server") },
                      "never received the banner; got: \(collector.text)")
        // Negotiation must be stripped: no raw 0xFF should reach the terminal.
        XCTAssertFalse(collector.text.unicodeScalars.contains("\u{FF}"),
                       "IAC leaked into terminal output")
    }

    /// The negotiation the server asked for, seen from the server's side.
    func testNegotiatesTerminalTypeAndWindowSize() async throws {
        try requireServer()
        let collector = Collector()
        let connection = try await TelnetConnection.connect(
            config: config(), cols: 120, rows: 40,
            onData: { collector.append($0) },
            onExit: { _ in })
        defer { connection.close() }

        XCTAssertTrue(waitFor { serverLog().contains("TTYPE=") },
                      "server never got a terminal type; log:\n\(serverLog())")
        XCTAssertTrue(serverLog().contains("TTYPE=xterm-256color"),
                      "wrong terminal type; log:\n\(serverLog())")
        XCTAssertTrue(waitFor { serverLog().contains("NAWS=120x40") },
                      "server never got the window size; log:\n\(serverLog())")
        XCTAssertTrue(serverLog().contains("DO ECHO"),
                      "client did not accept the server's offer to echo")
        // An option nobody supports must be refused out loud, not ignored —
        // a server may wait forever for an answer.
        XCTAssertTrue(serverLog().contains("WONT 99"),
                      "unknown option was not refused; log:\n\(serverLog())")
    }

    func testResizePropagates() async throws {
        try requireServer()
        let connection = try await TelnetConnection.connect(
            config: config(), cols: 80, rows: 24,
            onData: { _ in }, onExit: { _ in })
        defer { connection.close() }

        XCTAssertTrue(waitFor { serverLog().contains("NAWS=80x24") })
        connection.resize(cols: 132, rows: 50)
        XCTAssertTrue(waitFor { serverLog().contains("NAWS=132x50") },
                      "resize never reached the server; log:\n\(serverLog())")
    }

    /// Typing has to arrive as typed, and Enter has to be a line terminator the
    /// server recognises.
    func testTypedInputReachesTheServerAsALine() async throws {
        try requireServer()
        let collector = Collector()
        let connection = try await TelnetConnection.connect(
            config: config(), cols: 80, rows: 24,
            onData: { collector.append($0) },
            onExit: { _ in })
        defer { connection.close() }

        XCTAssertTrue(waitFor { collector.text.contains("login:") })
        connection.write(Data("hello\r".utf8))

        XCTAssertTrue(waitFor { serverLog().contains("LINE=hello") },
                      "server never saw a complete line; log:\n\(serverLog())")
        XCTAssertTrue(waitFor { collector.text.contains("you said: hello") },
                      "no reply came back; got: \(collector.text)")
    }

    func testClosingIsReportedToTheCaller() async throws {
        try requireServer()
        let exited = expectation(description: "onExit called")
        let connection = try await TelnetConnection.connect(
            config: config(), cols: 80, rows: 24,
            onData: { _ in },
            onExit: { _ in exited.fulfill() })

        // "quit" makes the test server hang up on us.
        connection.write(Data("quit\r".utf8))
        await fulfillment(of: [exited], timeout: 10)
        connection.close()
    }

    func testConnectingToADeadPortFailsPromptly() async throws {
        let dead = SessionConfig(name: "nothing", host: "127.0.0.1", port: 1,
                                 username: "", kind: "telnet")
        do {
            let connection = try await TelnetConnection.connect(
                config: dead, onData: { _ in }, onExit: { _ in })
            connection.close()
            XCTFail("connecting to a closed port should not succeed")
        } catch {
            // Expected. The message has to name the address, or a failed
            // connection in the UI says nothing useful.
            XCTAssertTrue("\(error)".contains("127.0.0.1:1"), "unhelpful error: \(error)")
        }
    }
}

import XCTest

@testable import MacMobaCore

/// Multi-hop (ssh -J b,a) and gateway failover, against real SSH servers.
///
/// Needs three servers (from TestSupport/):
///
///     node ssh-server.js                       # hop1, 2299, MM_RX_LOG=…/fwd-2299.log
///     sed 's/2299/2406/' … > ssh-bastion.js    # hop2, 2406, MM_RX_LOG=…/fwd-2406.log
///     sed 's/2299/2407/' … > ssh-target.js     # target, 2407 (home has behind-the-bastion.txt)
///
/// The proof for multi-hop is not "the target was reached" — on localhost every
/// port is reachable directly — but that the traffic went THROUGH both bastions,
/// read from each bastion's own forward log.
final class MultiHopFailoverTests: XCTestCase {
    private static let host = "127.0.0.1"

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

    private func session(_ id: String, port: Int, jump: String? = nil) -> SessionConfig {
        var s = SessionConfig(id: id, name: id, host: Self.host, port: port,
                              username: "test", authType: "password", password: "secret")
        s.proxyJump = jump
        return s
    }

    // MARK: - multi-hop

    func testTwoBastionChainReachesTheTargetThroughBoth() async throws {
        try XCTSkipUnless(listening(2299) && listening(2406) && listening(2407),
                          "three chained SSH servers not running")
        let hop1 = session("hop1", port: 2299)
        let hop2 = session("hop2", port: 2406, jump: "hop1")
        let target = session("target", port: 2407, jump: "hop2")
        let all = [hop1, hop2, target]

        // The chain the app would resolve: outermost (reachable) first.
        let chain = JumpChain.resolve(for: target, sessions: all)
        XCTAssertEqual(chain.map(\.id), ["hop1", "hop2"])

        // SFTP through the chain must land on the TARGET's filesystem — its home
        // has a file the two bastions do not.
        let client = try await SFTPClient.connect(config: target, via: chain)
        defer { client.close() }
        let names = try await client.list(try await client.realpath(".")).map(\.name)
        XCTAssertTrue(names.contains("behind-the-bastion.txt"),
                      "should be listing the target (2407), got \(names)")
    }

    /// Ground truth from the bastions' own logs: hop1 forwarded to hop2, and
    /// hop2 forwarded to the target. Reads logs the previous test's connection
    /// wrote; skipped if logging is not enabled.
    func testTrafficTraversedBothBastions() async throws {
        try XCTSkipUnless(listening(2299) && listening(2406) && listening(2407),
                          "three chained SSH servers not running")
        let scratch = ProcessInfo.processInfo.environment["MM_FWD_DIR"]
        try XCTSkipIf(scratch == nil, "set MM_FWD_DIR to where the forward logs are")

        let hop1 = session("hop1", port: 2299)
        let hop2 = session("hop2", port: 2406, jump: "hop1")
        let target = session("target", port: 2407, jump: "hop2")
        let chain = JumpChain.resolve(for: target, sessions: [hop1, hop2, target])
        let client = try await SFTPClient.connect(config: target, via: chain)
        _ = try await client.realpath(".")
        client.close()
        try await Task.sleep(nanoseconds: 300_000_000)

        let hop1Log = (try? String(contentsOfFile: scratch! + "/fwd-2299.log",
                                   encoding: .utf8)) ?? ""
        let hop2Log = (try? String(contentsOfFile: scratch! + "/fwd-2406.log",
                                   encoding: .utf8)) ?? ""
        XCTAssertTrue(hop1Log.contains("forward:127.0.0.1:2406"),
                      "hop1 should have tunnelled to hop2, log: \(hop1Log)")
        XCTAssertTrue(hop2Log.contains("forward:127.0.0.1:2407"),
                      "hop2 should have tunnelled to the target, log: \(hop2Log)")
    }

    // MARK: - failover

    /// The primary address is dead; a fallback is alive. The connection must
    /// come up on the fallback rather than fail.
    func testFailoverToWorkingFallback() async throws {
        try XCTSkipUnless(listening(2299), "no SSH test server on 2299")
        var target = SessionConfig(id: "f", name: "f", host: Self.host, port: 59999,
                                   username: "test", authType: "password", password: "secret")
        target.fallbackHosts = ["127.0.0.1:2299"]   // the real server

        let sink = SinkBox()
        let conn = try await SSHConnection.connect(
            config: target, cols: 80, rows: 24,
            onData: { sink.append($0) }, onExit: { _ in })
        defer { conn.close() }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !sink.text.contains("Welcome to smoke-server") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sink.text.contains("Welcome to smoke-server"),
                      "should have failed over to the working fallback")
    }

    /// No fallback and a dead primary must still fail — failover is not a way to
    /// paper over a genuinely unreachable host.
    func testDeadPrimaryWithNoFallbackFails() async throws {
        let target = SessionConfig(id: "d", name: "d", host: Self.host, port: 59998,
                                   username: "test", authType: "password", password: "secret")
        do {
            _ = try await SSHConnection.connect(
                config: target, onData: { _ in }, onExit: { _ in })
            XCTFail("a dead host with no fallback must not connect")
        } catch {
            // expected
        }
    }

    private final class SinkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
    }
}

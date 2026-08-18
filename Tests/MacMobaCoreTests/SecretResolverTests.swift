import XCTest

@testable import MacMobaCore

/// The whole password-manager pipeline: a stored reference becomes a subprocess
/// whose output is the real password, and that password authenticates.
///
/// The `cmd:` form is exercised here because it needs nothing installed — the
/// exact same path runs `op read` for a 1Password reference.
final class SecretResolverTests: XCTestCase {
    private static let host = "127.0.0.1"
    private static let port = 2299

    private func serverUp() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(Self.port).bigEndian
        inet_pton(AF_INET, Self.host, &addr.sin_addr)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    // MARK: - resolution

    func testLiteralIsUnchanged() async throws {
        let value = try await SecretResolver.resolve("plainpassword")
        XCTAssertEqual(value, "plainpassword")
    }

    func testCommandOutputBecomesTheSecret() async throws {
        let value = try await SecretResolver.resolve("cmd:printf secret")
        XCTAssertEqual(value, "secret")
    }

    func testTrailingNewlineIsTrimmed() async throws {
        // echo adds a newline; a password field should not keep it.
        let value = try await SecretResolver.resolve("cmd:echo hunter2")
        XCTAssertEqual(value, "hunter2")
    }

    func testInnerSpacesArePreserved() async throws {
        let value = try await SecretResolver.resolve("cmd:printf 'a b c'")
        XCTAssertEqual(value, "a b c")
    }

    func testFailingCommandThrows() async throws {
        do {
            _ = try await SecretResolver.resolve("cmd:exit 3")
            XCTFail("a failing fetch command must throw")
        } catch {
            // expected
        }
    }

    /// A manager stuck waiting (1Password authorization no one can see) must
    /// become an error, not a connection that hangs forever.
    func testHungCommandTimesOut() async {
        let start = Date()
        do {
            _ = try await SecretResolver.resolve("cmd:sleep 30", timeout: 1)
            XCTFail("a hung fetch command must throw")
        } catch let error as SecretResolver.ResolveError {
            guard case .timedOut = error else {
                return XCTFail("expected .timedOut, got \(error)")
            }
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("1Password"), "error should hint at the likely cause")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "timeout did not cut the wait short")
    }

    /// A tool that prompts on stdin sees EOF (null device), so it fails fast
    /// instead of waiting for typing that can never arrive.
    func testStdinIsClosedNotATerminal() async {
        do {
            // `read` returns non-zero immediately at EOF; without the null
            // stdin it would block on the inherited descriptor.
            _ = try await SecretResolver.resolve("cmd:read x", timeout: 5)
            XCTFail("read-at-EOF should exit non-zero and throw")
        } catch let error as SecretResolver.ResolveError {
            if case .timedOut = error {
                XCTFail("stdin should be EOF — the command must fail, not hang until timeout")
            }
            // .failed is the expected shape
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testResolveSessionFillsInPassword() async throws {
        var s = SessionConfig(name: "s", host: "h", username: "u",
                              authType: "password", password: "cmd:printf fromCmd")
        s.passphrase = "cmd:printf pp"
        let resolved = try await SecretResolver.resolve(session: s)
        XCTAssertEqual(resolved.password, "fromCmd")
        XCTAssertEqual(resolved.passphrase, "pp")
    }

    // MARK: - end to end

    /// A session whose stored password is a `cmd:` reference — not the literal —
    /// authenticates once resolved. The reference resolves to "secret", the test
    /// server's password; the literal string "cmd:printf secret" never would.
    func testReferenceResolvesAndAuthenticates() async throws {
        try XCTSkipUnless(serverUp(), "no SSH test server on \(Self.host):\(Self.port)")
        let stored = SessionConfig(name: "s", host: Self.host, port: Self.port,
                                   username: "test", authType: "password",
                                   password: "cmd:printf secret")
        let resolved = try await SecretResolver.resolve(session: stored)
        XCTAssertEqual(resolved.password, "secret")

        let sink = TextSink()
        let conn = try await SSHConnection.connect(
            config: resolved, cols: 80, rows: 24,
            onData: { sink.append($0) }, onExit: { _ in })
        defer { conn.close() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !sink.text.contains("Welcome to smoke-server") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sink.text.contains("Welcome to smoke-server"),
                      "the resolved password should authenticate")
    }

    private final class TextSink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
    }
}

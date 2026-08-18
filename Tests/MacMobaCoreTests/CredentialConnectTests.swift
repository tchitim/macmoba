import XCTest

@testable import MacMobaCore

/// The unit tests prove the resolver picks the right login; this proves the
/// resolved login actually authenticates. It mirrors what the app does at
/// connect time — resolve the stored session, then hand the result to
/// SSHConnection — against the real test SSH server.
///
/// Needs: `node TestSupport/ssh-server.js` (user "test" / password "secret").
final class CredentialConnectTests: XCTestCase {
    private static let host = "127.0.0.1"
    private static let port = 2299

    private func serverAvailable() -> Bool {
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

    /// A session whose OWN fields are wrong, so that a successful login can only
    /// come from the shared credential — the negative control is built in.
    private func sessionWithWrongInline(ref: String, group: String? = nil) -> SessionConfig {
        var s = SessionConfig(id: "s", name: "s", host: Self.host, port: Self.port,
                              username: "WRONG-USER", authType: "password",
                              password: "WRONG-PW")
        s.credentialRef = ref
        s.group = group
        return s
    }

    private let goodCredential = CredentialConfig(id: "cred", name: "Lab", username: "test",
                                                  authType: "password", password: "secret")

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
    }

    private func bannerAppears(connecting config: SessionConfig) async throws -> Bool {
        let sink = Sink()
        let conn = try await SSHConnection.connect(
            config: config, cols: 80, rows: 24,
            onData: { sink.append($0) }, onExit: { _ in })
        defer { conn.close() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if sink.text.contains("Welcome to smoke-server") { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// The control: the wrong inline login, unresolved, must be rejected — so
    /// that a later success can only be the credential's doing.
    func testWrongInlineLoginIsRejected() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let session = sessionWithWrongInline(ref: "custom")
        do {
            _ = try await bannerAppears(connecting: session)
            XCTFail("wrong inline credentials must not authenticate")
        } catch {
            // expected: auth failure
        }
    }

    /// Referencing the shared credential makes the wrong inline login succeed.
    func testExplicitCredentialAuthenticates() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let session = sessionWithWrongInline(ref: "cred")
        let resolved = CredentialResolver.resolve(session, credentials: [goodCredential],
                                                  groupCredentials: [:])
        XCTAssertEqual(resolved.username, "test", "resolver should have supplied the credential")
        let connected = try await bannerAppears(connecting: resolved)
        XCTAssertTrue(connected, "the resolved credential should authenticate")
    }

    /// Group inheritance authenticates the same way.
    func testInheritedCredentialAuthenticates() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let session = sessionWithWrongInline(ref: CredentialResolver.inherit, group: "Production")
        let resolved = CredentialResolver.resolve(session, credentials: [goodCredential],
                                                  groupCredentials: ["Production": "cred"])
        let connected = try await bannerAppears(connecting: resolved)
        XCTAssertTrue(connected, "the inherited credential should authenticate")
    }
}

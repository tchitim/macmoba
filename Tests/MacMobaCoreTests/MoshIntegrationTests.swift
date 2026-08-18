import XCTest
@testable import MacMobaCore

/// Against a real `mosh-server` reached over a real SSH connection.
///
/// The unit tests parse greetings I wrote; this checks the greeting an actual
/// mosh-server produces, and that the SSH exec channel delivers it.
///
/// Needs a host running sshd + mosh-server. See STATUS.md for the container.
final class MoshIntegrationTests: XCTestCase {

    private let host = "127.0.0.1"
    // 2223, not 2222: OpenSSHInteropTests owns 2222 for its own sshd, and a
    // container squatting there makes those tests fail auth instead of skip.
    private let port = 2223

    private func config() -> SessionConfig {
        SessionConfig(name: "mosh-test", host: host, port: port,
                      username: "tester", authType: "password",
                      password: "secret", kind: "mosh")
    }

    private func requireServer() throws {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw XCTSkip("no socket") }
        defer { Darwin.close(socketDescriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw XCTSkip("mosh test container not running on \(host):\(port)")
        }
    }

    /// The whole first half of a Mosh connection.
    func testStartsARealMoshServerAndReadsItsGreeting() async throws {
        try requireServer()
        let output = try await SSHConnection.runCommand(
            MoshBootstrap.serverCommand(), config: config())

        let session = try MoshBootstrap.parse(output)
        // mosh-server allocates from 60000 upwards by default.
        XCTAssertGreaterThanOrEqual(session.port, 60000)
        XCTAssertLessThan(session.port, 61001)
        // The key is base64 of 16 bytes, so 22 characters with no padding.
        XCTAssertEqual(session.key.count, 22, "unexpected key shape: \(session.key)")
        XCTAssertFalse(session.key.contains(" "))
    }

    /// Two sessions must not collide — each gets its own port and its own key.
    func testEachSessionGetsItsOwnPortAndKey() async throws {
        try requireServer()
        let first = try MoshBootstrap.parse(
            try await SSHConnection.runCommand(MoshBootstrap.serverCommand(), config: config()))
        let second = try MoshBootstrap.parse(
            try await SSHConnection.runCommand(MoshBootstrap.serverCommand(), config: config()))

        XCTAssertNotEqual(first.port, second.port)
        XCTAssertNotEqual(first.key, second.key,
                          "two sessions sharing a key would be a serious problem")
    }

    /// The command has to run as an SSH exec, not by typing at a login shell:
    /// otherwise the reply arrives mixed into a prompt and a motd.
    func testGreetingIsNotPollutedByTheLoginShell() async throws {
        try requireServer()
        let output = try await SSHConnection.runCommand(
            MoshBootstrap.serverCommand(), config: config())
        let connectLines = output.split(whereSeparator: \.isNewline)
            .filter { $0.contains("MOSH CONNECT") }
        XCTAssertEqual(connectLines.count, 1, "expected exactly one greeting, got:\n\(output)")
    }

    /// A missing mosh-server has to be reported as such rather than as a parse
    /// failure — it is the most common way this goes wrong.
    func testMissingServerIsDiagnosed() async throws {
        try requireServer()
        let output = try await SSHConnection.runCommand(
            "definitely-not-mosh-server new -s", config: config())
        XCTAssertThrowsError(try MoshBootstrap.parse(output)) { error in
            XCTAssertEqual(error as? MoshError, .serverNotFound,
                           "server output was: \(output)")
        }
    }
}

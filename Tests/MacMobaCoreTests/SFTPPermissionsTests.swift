import XCTest

@testable import MacMobaCore

/// chmod over SFTP, verified against the real file on disk, and the dotfile
/// filter the browser uses.
///
/// Needs the test SSH server (its SFTP serves the real filesystem):
///     node TestSupport/ssh-server.js
final class SFTPPermissionsTests: XCTestCase {
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

    private func session() -> SessionConfig {
        SessionConfig(name: "t", host: Self.host, port: Self.port,
                      username: "test", authType: "password", password: "secret")
    }

    /// setPermissions changes the real file's mode — read back both from the
    /// filesystem and from a fresh SFTP listing.
    func testChmodChangesTheMode() async throws {
        try XCTSkipUnless(serverUp(), "no SSH test server on \(Self.host):\(Self.port)")
        let client = try await SFTPClient.connect(config: session())
        defer { client.close() }

        // A file we own, in a temp dir the SFTP server can see (it serves the
        // real filesystem with no chroot).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-chmod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("perms.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try await client.setPermissions(file.path, mode: 0o600)

        // Ground truth #1: the real file on disk.
        let onDisk = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(onDisk.map { $0 & 0o7777 }, 0o600)

        // Ground truth #2: a fresh SFTP listing reports the new mode.
        let listed = try await client.list(dir.path).first { $0.name == "perms.txt" }
        XCTAssertEqual((listed?.attributes.permissions ?? 0) & 0o7777, 0o600)
    }

    /// Only the permission bits change — the file-type bits (and the fact it is
    /// a regular file) are untouched.
    func testChmodKeepsFileType() async throws {
        try XCTSkipUnless(serverUp(), "no SSH test server on \(Self.host):\(Self.port)")
        let client = try await SFTPClient.connect(config: session())
        defer { client.close() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-chmod2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        try await client.setPermissions(file.path, mode: 0o755)
        let listed = try await client.list(dir.path).first { $0.name == "f" }
        XCTAssertFalse(listed?.isDirectory ?? true, "should still be a regular file")
        XCTAssertEqual((listed?.attributes.permissions ?? 0) & 0o777, 0o755)
    }
}

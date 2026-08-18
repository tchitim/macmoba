import XCTest
@testable import MacMobaCore

/// Uploading pasted-image bytes to the remote, verified byte-for-byte against
/// the real file on disk (the test SFTP server serves the local filesystem).
///
/// Needs the test SSH server: node TestSupport/ssh-server.js
final class RemotePasteUploadTests: XCTestCase {
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

    func testUploadLandsByteForByte() async throws {
        try XCTSkipUnless(serverUp(), "no SSH test server on \(Self.host):\(Self.port)")

        // Binary payload with a PNG header and awkward bytes (NUL, 0xFF, BEL) —
        // anything short of byte-exact transfer fails the comparison.
        var payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        payload.append(Data((0..<4096).map { UInt8($0 % 256) }))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-paste-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let remote = try await RemotePasteUpload.upload(
            data: payload, fileName: "shot.png", config: session(), directory: dir)

        XCTAssertEqual(remote, dir + "/shot.png", "returned path must be typed-in-able")
        // Ground truth: the very bytes, straight off the disk the server serves.
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: remote))
        XCTAssertEqual(onDisk, payload)
    }

    func testUploadIntoExistingDirectoryStillWorks() async throws {
        try XCTSkipUnless(serverUp(), "no SSH test server on \(Self.host):\(Self.port)")
        // mkdir hitting EEXIST must not fail the upload.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-paste-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let payload = Data("second".utf8)
        let remote = try await RemotePasteUpload.upload(
            data: payload, fileName: "again.png", config: session(), directory: dir)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), payload)
    }
}

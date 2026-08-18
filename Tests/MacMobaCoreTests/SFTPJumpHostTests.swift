import XCTest

@testable import MacMobaCore

/// SFTP must take the same route as the terminal.
///
/// The bug: `SFTPClient.connect` dialled the target directly while the terminal
/// beside it went through the configured jump host. On a network where only the
/// bastion can reach the target, the terminal worked and the file browser sat
/// on "Connecting…" forever.
///
/// Needs two test servers (from TestSupport/):
///
///     sed 's/srv.listen(2299/srv.listen(2406/' ssh-server.js > ssh-bastion.js
///     sed 's/srv.listen(2299/srv.listen(2407/' ssh-server.js > ssh-target.js
///     HOME=…/bastionHome node ssh-bastion.js
///     HOME=…/targetHome  node ssh-target.js
final class SFTPJumpHostTests: XCTestCase {
    private static let host = "127.0.0.1"
    private static let bastionPort = 2406
    private static let targetPort = 2407

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

    private func session(_ name: String, port: Int, id: String) -> SessionConfig {
        SessionConfig(id: id, name: name, host: Self.host, port: port,
                      username: "test", authType: "password", password: "secret")
    }

    /// The whole point: an SFTP session opened with `via:` reaches a host
    /// through the bastion and can list its files.
    func testSFTPReachesTheTargetThroughTheBastion() async throws {
        try XCTSkipUnless(listening(Self.bastionPort) && listening(Self.targetPort),
                          "bastion/target test servers not running")
        let bastion = session("bastion", port: Self.bastionPort, id: "jump")
        var target = session("target", port: Self.targetPort, id: "target")
        target.proxyJump = bastion.id

        let client = try await SFTPClient.connect(config: target, via: [bastion])
        defer { client.close() }

        let home = try await client.realpath(".")
        let names = try await client.list(home).map(\.name)
        XCTAssertTrue(names.contains("behind-the-bastion.txt"),
                      "should be listing the TARGET's files, got \(names)")
    }

    /// And the file it lists really is the target's, not the bastion's — the
    /// two servers serve different directories on purpose.
    func testItIsTheTargetsFilesystemNotTheBastions() async throws {
        try XCTSkipUnless(listening(Self.bastionPort) && listening(Self.targetPort),
                          "bastion/target test servers not running")
        let bastion = session("bastion", port: Self.bastionPort, id: "jump")
        let target = session("target", port: Self.targetPort, id: "target")

        let viaJump = try await SFTPClient.connect(config: target, via: [bastion])
        let throughJumpNames = try await viaJump.list(try await viaJump.realpath("."))
            .map(\.name)
        viaJump.close()

        let direct = try await SFTPClient.connect(config: bastion)
        let bastionNames = try await direct.list(try await direct.realpath(".")).map(\.name)
        direct.close()

        XCTAssertTrue(throughJumpNames.contains("behind-the-bastion.txt"))
        XCTAssertFalse(bastionNames.contains("behind-the-bastion.txt"),
                       "the two servers must be serving different directories "
                       + "or this test proves nothing")
    }

    /// A transfer over the jumped connection has to work, not just the listing.
    func testDownloadWorksThroughTheBastion() async throws {
        try XCTSkipUnless(listening(Self.bastionPort) && listening(Self.targetPort),
                          "bastion/target test servers not running")
        let bastion = session("bastion", port: Self.bastionPort, id: "jump")
        let target = session("target", port: Self.targetPort, id: "target")

        let client = try await SFTPClient.connect(config: target, via: [bastion])
        defer { client.close() }
        let home = try await client.realpath(".")
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("jump-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: local) }

        try await client.download(remotePath: "\(home)/behind-the-bastion.txt",
                                  to: local, progress: nil)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8),
                       "only-reachable-via-jump\n")
    }
}

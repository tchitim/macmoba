import XCTest

@testable import MacMobaCore

/// The FTP client against a real server (vsftpd in Docker).
///
/// The parser tests cover the text; this covers everything that only shows up
/// on a wire: passive-mode negotiation, the order of the data connection
/// against the control replies, and binary transfers surviving intact.
///
/// Start the server with:
///
///     docker run -d --name mm-ftp -p 2121:21 -p 30000-30009:30000-30009 \
///       -e FTP_USER=tester -e FTP_PASS=ftppass -e PASV_ADDRESS=127.0.0.1 \
///       -e PASV_MIN_PORT=30000 -e PASV_MAX_PORT=30009 fauria/vsftpd
///
/// Every test skips when it is not running, so the suite stays green on a
/// machine without Docker.
final class FTPInteropTests: XCTestCase {
    private static let host = "127.0.0.1"
    private static let port = 2121

    private func config(user: String = "tester", password: String = "ftppass") -> SessionConfig {
        SessionConfig(name: "ftp-test", host: Self.host, port: Self.port,
                      username: user, authType: "password", password: password,
                      kind: "ftp")
    }

    private func serverAvailable() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(Self.port).bigEndian
        inet_pton(AF_INET, Self.host, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func connected() async throws -> FTPClient {
        try XCTSkipUnless(serverAvailable(), "no FTP server on \(Self.host):\(Self.port)")
        return try await FTPClient.connect(config: config())
    }

    /// A unique subdirectory per test, removed afterwards.
    ///
    /// Cleanup is AWAITED rather than left to `defer { Task { … } }`: a
    /// detached task does not necessarily run before the test process exits,
    /// which quietly littered the server with scratch directories and then
    /// failed a later assertion that looked for leftovers.
    private func withScratch(_ name: String, _ client: FTPClient,
                             _ body: (String) async throws -> Void) async throws {
        let path = "/scratch-\(name)-\(UUID().uuidString.prefix(8))"
        try await client.mkdir(path)
        do {
            try await body(path)
        } catch {
            try? await client.removeDirectoryRecursively(path)
            throw error
        }
        try? await client.removeDirectoryRecursively(path)
    }

    func testLoginAndPWD() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        let home = try await client.realpath(".")
        XCTAssertTrue(home.hasPrefix("/"), "PWD should give an absolute path, got \(home)")
    }

    func testWrongPasswordIsRejected() async throws {
        try XCTSkipUnless(serverAvailable(), "no FTP server")
        do {
            let client = try await FTPClient.connect(config: config(password: "wrong"))
            await client.close()
            XCTFail("a bad password must not connect")
        } catch let error as FTPError {
            guard case .authenticationFailed = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
    }

    func testListingSeesTheSeededFiles() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        let items = try await client.list("/")
        let names = Set(items.map(\.name))
        XCTAssertTrue(names.contains("readme.txt"), "got \(names)")
        XCTAssertTrue(names.contains("subdir"), "got \(names)")
        let readme = try XCTUnwrap(items.first { $0.name == "readme.txt" })
        XCTAssertFalse(readme.isDirectory)
        XCTAssertEqual(readme.size, 26)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.name == "subdir" }).isDirectory)
    }

    /// The listing must never contain "." or "..", or the browser can descend
    /// into the folder it is already in, forever.
    func testListingHasNoDotEntries() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        let names = try await client.list("/").map(\.name)
        XCTAssertFalse(names.contains("."))
        XCTAssertFalse(names.contains(".."))
    }

    func testDownloadMatchesTheServerCopy() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }

        try await client.download(remotePath: "/readme.txt", to: local, progress: nil)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8),
                       "hello from the ftp server\n")
    }

    /// Binary, not text: the default transfer type is ASCII, which rewrites
    /// line endings and silently corrupts anything that is not text. TYPE I is
    /// sent at login precisely to stop that, and this is what proves it.
    func testBinaryRoundTripIsByteIdentical() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        // Bytes chosen to break an ASCII-mode transfer: bare CR, bare LF, CRLF,
        // NUL and a high byte.
        var bytes = Data([0x00, 0x0D, 0x0A, 0x0D, 0x0A, 0xFF, 0x1A, 0x41])
        bytes.append(contentsOf: (0...255).map { UInt8($0) })
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-binary-\(UUID().uuidString)")
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try await withScratch("binary", client) { directory in
            let remote = "\(directory)/blob.bin"
            try await client.upload(localURL: source, to: remote, progress: nil)

            let roundTripped = FileManager.default.temporaryDirectory
                .appendingPathComponent("ftp-binary-back-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: roundTripped) }
            try await client.download(remotePath: remote, to: roundTripped, progress: nil)

            XCTAssertEqual(try Data(contentsOf: roundTripped), bytes,
                           "an ASCII-mode transfer would have mangled the CR/LF bytes")
        }
    }

    func testUploadThenListShowsTheRightSize() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        let payload = String(repeating: "abcdefghij", count: 5000) // 50,000 bytes
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-upload-\(UUID().uuidString).txt")
        try payload.write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        try await withScratch("upload", client) { directory in
            try await client.upload(localURL: source, to: "\(directory)/big.txt", progress: nil)
            let items = try await client.list(directory)
            let uploaded = try XCTUnwrap(items.first { $0.name == "big.txt" })
            XCTAssertEqual(uploaded.size, 50_000)
        }
    }

    func testProgressIsReportedAndEndsAtTheTotal() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-progress-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: 300_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try await withScratch("progress", client) { directory in
            let reports = Reports()
            try await client.upload(localURL: source, to: "\(directory)/p.bin") { done, total in
                reports.record(done, total)
            }
            XCTAssertEqual(reports.last, 300_000, "the last report must be the whole file")
            XCTAssertEqual(reports.total, 300_000)
            XCTAssertGreaterThan(reports.count, 1, "a 300 KB file should report more than once")
        }
    }

    func testMkdirRenameAndRecursiveDelete() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        let directory = "/scratch-tree-\(UUID().uuidString.prefix(8))"
        try await client.mkdir(directory)

        try await client.mkdir("\(directory)/inner")
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-tree-\(UUID().uuidString).txt")
        try "x".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }
        try await client.upload(localURL: source, to: "\(directory)/inner/a.txt", progress: nil)

        try await client.rename("\(directory)/inner/a.txt", to: "\(directory)/inner/b.txt")
        let renamed = try await client.list("\(directory)/inner").map(\.name)
        XCTAssertEqual(renamed, ["b.txt"])

        // Recursive delete has to empty the tree depth-first; RMD on a
        // non-empty directory fails.
        try await client.removeDirectoryRecursively(directory)
        let root = try await client.list("/").map(\.name)
        // This directory specifically — not "anything that looks like one",
        // which would also catch leftovers from an earlier interrupted run.
        XCTAssertFalse(root.contains(String(directory.dropFirst())),
                       "the whole tree should be gone, got \(root)")
    }

    func testRenameOntoAMissingSourceFails() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        do {
            try await client.rename("/does-not-exist.txt", to: "/whatever.txt")
            XCTFail("renaming a missing file must fail")
        } catch let error as FTPError {
            guard case .server = error else {
                return XCTFail("expected a server error, got \(error)")
            }
        }
    }

    /// Several commands in a row on one connection: this is what breaks when
    /// the reply parser leaves bytes behind and the control stream drifts out
    /// of step.
    func testManyCommandsStayInSync() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        for _ in 0..<12 {
            let home = try await client.realpath(".")
            XCTAssertTrue(home.hasPrefix("/"))
            let items = try await client.list("/")
            XCTAssertTrue(items.contains { $0.name == "readme.txt" })
        }
    }

    func testRecursiveDirectoryDownload() async throws {
        let client = try await connected()
        defer { Task { await client.close() } }
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }

        try await client.downloadDirectory(remotePath: "/subdir", to: local, progress: nil)
        let nested = local.appendingPathComponent("nested.txt")
        XCTAssertEqual(try String(contentsOf: nested, encoding: .utf8), "nested\n")
    }

    /// A jump host cannot work with passive mode, so it is refused up front
    /// rather than connecting and then stalling on the first listing.
    func testJumpHostIsRefusedClearly() async throws {
        var jumped = config()
        jumped.proxyJump = "some-ssh-session"
        do {
            let client = try await FTPClient.connect(config: jumped)
            await client.close()
            XCTFail("FTP through a jump host must be refused")
        } catch let error as FTPError {
            guard case .unsupported = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
        }
    }

    /// Progress callbacks arrive on whatever thread the transfer is on.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(UInt64, UInt64?)] = []

        func record(_ done: UInt64, _ total: UInt64?) {
            lock.lock(); defer { lock.unlock() }
            values.append((done, total))
        }
        var last: UInt64? { lock.lock(); defer { lock.unlock() }; return values.last?.0 }
        var total: UInt64? { lock.lock(); defer { lock.unlock() }; return values.last?.1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    }
}

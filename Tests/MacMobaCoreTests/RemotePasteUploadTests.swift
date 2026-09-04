import XCTest
import os
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

// MARK: - Retention, against the real server

extension RemotePasteUploadTests {
    /// The sweep really deletes, and really spares everything else.
    ///
    /// The rule itself is covered by RemotePasteRetentionTests; this is the
    /// other half — that the delete reaches the far side at all, which a pure
    /// test cannot show.
    func testSweepRemovesOnlyExpiredPastes() async throws {
        try XCTSkipUnless(serverUp(), "needs: node TestSupport/ssh-server.js")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let stale = "paste-\(Int(now.timeIntervalSince1970 - 8 * 86_400)).png"
        let fresh = "paste-\(Int(now.timeIntervalSince1970 - 1 * 86_400)).png"
        let theirs = "important.png"
        for name in [stale, fresh, theirs] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        let client = try await SFTPClient.connect(config: session(), via: [], hostKeys: nil)
        defer { client.close() }
        await RemotePasteUpload.sweepExpired(in: dir.path, using: client, now: now)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertFalse(left.contains(stale), "the eight-day-old paste should be gone")
        XCTAssertTrue(left.contains(fresh), "a one-day-old paste must survive")
        XCTAssertTrue(left.contains(theirs), "a file that is not ours must survive")
    }
}

// MARK: - Per-session folder, against the real server

extension RemotePasteUploadTests {
    /// Two sessions on the same host land in different folders, and the file
    /// really is inside its own.
    ///
    /// The slug rules are covered purely; this is the half a pure test cannot
    /// show — that the directory gets created on the far side at all, since
    /// mkdir does not make intermediates.
    func testEachSessionUploadsIntoItsOwnFolder() async throws {
        try XCTSkipUnless(serverUp(), "needs: node TestSupport/ssh-server.js")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func upload(sessionNamed name: String) async throws -> String {
            var config = session()
            config.name = name
            let dir = root.appendingPathComponent(RemotePasteFolder.slug(for: name)).path
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            return try await RemotePasteUpload.upload(
                data: Data("shot".utf8), fileName: "paste-1.png",
                config: config, directory: dir)
        }

        let a = try await upload(sessionNamed: "haoji")
        let b = try await upload(sessionNamed: "macmoba-swift")

        XCTAssertTrue(a.contains("/haoji/"), a)
        XCTAssertTrue(b.contains("/macmoba-swift/"), b)
        XCTAssertNotEqual(a, b, "same filename in two sessions must not collide")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: a)), Data("shot".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: b)), Data("shot".utf8))
    }
}

// MARK: - Pipelined download correctness

/// Downloads are pipelined — several reads in flight, replies written at their
/// own offsets. That is exactly the shape that corrupts a file if the ordering
/// is wrong, so these compare bytes rather than sizes.
final class SFTPDownloadIntegrityTests: XCTestCase {
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

    /// Sizes chosen around the 32 KB chunk and the 16-chunk window: empty, a
    /// part chunk, an exact chunk, a part window, an exact window, and past it
    /// — the boundaries where an off-by-one in the pipelining would show.
    func testDownloadsAreByteExactAcrossChunkAndWindowBoundaries() async throws {
        try XCTSkipUnless(serverUp(), "needs: node TestSupport/ssh-server.js")

        let chunk = 32 * 1024
        let window = 16 * chunk
        let sizes = [0, 1, chunk - 1, chunk, chunk + 1,
                     window - 1, window, window + 1, window + chunk + 777]

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = try await SFTPClient.connect(config: session(), via: [], hostKeys: nil)
        defer { client.close() }

        for size in sizes {
            // Pseudo-random rather than a repeating pattern: a misordered or
            // duplicated chunk stays invisible against repeating bytes.
            var generator = SystemRandomNumberGenerator()
            var payload = Data(count: size)
            payload.withUnsafeMutableBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<size { base[i] = UInt8.random(in: 0...255, using: &generator) }
            }
            let source = dir.appendingPathComponent("src-\(size).bin")
            let dest = dir.appendingPathComponent("dst-\(size).bin")
            try payload.write(to: source)

            try await client.download(remotePath: source.path, to: dest)

            let got = try Data(contentsOf: dest)
            XCTAssertEqual(got.count, size, "wrong length for \(size) bytes")
            XCTAssertEqual(got, payload, "bytes differ for \(size) bytes")
        }
    }

    /// Progress must never run backwards or overshoot, since it drives a bar.
    func testProgressIsMonotonicAndBounded() async throws {
        try XCTSkipUnless(serverUp(), "needs: node TestSupport/ssh-server.js")

        let size = 20 * 32 * 1024 + 123
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-prog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src.bin")
        try Data(repeating: 7, count: size).write(to: source)

        let client = try await SFTPClient.connect(config: session(), via: [], hostKeys: nil)
        defer { client.close() }

        let seen = OSAllocatedUnfairLock(initialState: [UInt64]())
        try await client.download(remotePath: source.path,
                                  to: dir.appendingPathComponent("dst.bin")) { done, _ in
            seen.withLock { $0.append(done) }
        }
        let values = seen.withLock { $0 }
        XCTAssertFalse(values.isEmpty, "no progress was reported at all")
        XCTAssertEqual(values, values.sorted(), "progress went backwards")
        XCTAssertLessThanOrEqual(values.last ?? 0, UInt64(size))
        XCTAssertEqual(values.last, UInt64(size), "final progress must reach the size")
    }
}

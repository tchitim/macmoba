// SFTP integration tests against TestSupport/ssh-server.js (port 2299),
// whose sftp subsystem serves the real local filesystem — so the tests
// create a local temp dir and verify remote operations land in it.
// Skipped automatically when the server is not running.

import Foundation
import XCTest

@testable import MacMobaCore

final class SFTPIntegrationTests: XCTestCase {
    static let host = "127.0.0.1"
    static let port = 2299

    private func serverAvailable() -> Bool {
        #if canImport(Darwin)
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
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

    private func testSession() -> SessionConfig {
        SessionConfig(
            name: "test", host: Self.host, port: Self.port,
            username: "test", authType: "password", password: "secret"
        )
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmoba-sftp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRealpathAndList() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let sftp = try await SFTPClient.connect(config: testSession())
        defer { sftp.close() }

        let real = try await sftp.realpath(dir.path)
        XCTAssertEqual(real, dir.resolvingSymlinksInPath().path)

        let items = try await sftp.list(real)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["a.txt", "sub"])
        XCTAssertEqual(byName["a.txt"]?.size, 5)
        XCTAssertEqual(byName["a.txt"]?.isDirectory, false)
        XCTAssertEqual(byName["sub"]?.isDirectory, true)

        let attrs = try await sftp.stat(real + "/a.txt")
        XCTAssertEqual(attrs.size, 5)
    }

    func testUploadDownloadRoundtrip() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // > 2 chunks (32 KB each) to exercise offset handling
        var payload = Data(count: 100_000)
        payload.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8((i &* 31) & 0xff) }
        }
        let localSrc = dir.appendingPathComponent("src.bin")
        try payload.write(to: localSrc)

        let sftp = try await SFTPClient.connect(config: testSession())
        defer { sftp.close() }

        let remote = dir.path + "/uploaded.bin"
        try await sftp.upload(localURL: localSrc, to: remote)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), payload)

        let localDst = dir.appendingPathComponent("downloaded.bin")
        final class ProgressBox: @unchecked Sendable {
            let lock = NSLock()
            var value: UInt64 = 0
        }
        let progress = ProgressBox()
        try await sftp.download(remotePath: remote, to: localDst) { done, _ in
            progress.lock.lock()
            progress.value = done
            progress.lock.unlock()
        }
        XCTAssertEqual(try Data(contentsOf: localDst), payload)
        XCTAssertEqual(progress.value, UInt64(payload.count))
    }

    func testMkdirRenameDelete() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sftp = try await SFTPClient.connect(config: testSession())
        defer { sftp.close() }

        let newDir = dir.path + "/made-by-sftp"
        try await sftp.mkdir(newDir)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        let renamed = dir.path + "/renamed-dir"
        try await sftp.rename(newDir, to: renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed))

        let file = dir.appendingPathComponent("victim.txt")
        try Data("x".utf8).write(to: file)
        try await sftp.removeFile(file.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try await sftp.removeDirectory(renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed))
    }

    func testDirectoryRoundtrip() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // local tree: tree/a.txt, tree/sub/b.bin, tree/sub/deeper/c.txt, empty dir
        let tree = dir.appendingPathComponent("tree")
        let deeper = tree.appendingPathComponent("sub/deeper")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("aaa".utf8).write(to: tree.appendingPathComponent("a.txt"))
        try Data(repeating: 0xAB, count: 40_000).write(to: tree.appendingPathComponent("sub/b.bin"))
        try Data("ccc".utf8).write(to: deeper.appendingPathComponent("c.txt"))

        let sftp = try await SFTPClient.connect(config: testSession())
        defer { sftp.close() }

        let remote = dir.path + "/uploaded-tree"
        try await sftp.uploadDirectory(localURL: tree, to: remote)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: remote + "/sub/b.bin")).count, 40_000)
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: remote + "/sub/deeper/c.txt"), encoding: .utf8), "ccc")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote + "/empty", isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        let back = dir.appendingPathComponent("downloaded-tree")
        try await sftp.downloadDirectory(remotePath: remote, to: back)
        XCTAssertEqual(
            try String(contentsOf: back.appendingPathComponent("a.txt"), encoding: .utf8), "aaa")
        XCTAssertEqual(
            try Data(contentsOf: back.appendingPathComponent("sub/b.bin")),
            Data(repeating: 0xAB, count: 40_000))
        XCTAssertEqual(
            try String(contentsOf: back.appendingPathComponent("sub/deeper/c.txt"), encoding: .utf8), "ccc")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: back.appendingPathComponent("empty").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testDownloadCancellation() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Large enough that many 32 KB chunks remain after we cancel.
        let big = dir.appendingPathComponent("big.bin")
        try Data(count: 20_000_000).write(to: big)

        let sftp = try await SFTPClient.connect(config: testSession())
        defer { sftp.close() }

        final class TaskBox: @unchecked Sendable {
            var task: Task<Void, Error>?
        }
        let box = TaskBox()
        let dest = dir.appendingPathComponent("out.bin")
        box.task = Task {
            try await sftp.download(remotePath: big.path, to: dest) { done, _ in
                if done > 64_000 { box.task?.cancel() }
            }
        }
        do {
            try await box.task!.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // partial file only
            let written = (try? Data(contentsOf: dest).count) ?? 0
            XCTAssertLessThan(written, 20_000_000)
        }
    }

    func testRecursiveDelete() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // non-empty nested tree, like a dropped .app bundle
        let tree = dir.appendingPathComponent("bundle.app")
        let inner = tree.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: inner.appendingPathComponent("main"))
        try Data("plist".utf8).write(to: tree.appendingPathComponent("Contents/Info.plist"))

        let sftp = try await SFTPClient.connect(config: testSession())
        defer { sftp.close() }

        // plain RMDIR must fail on a non-empty dir (the bug this guards against)
        do {
            try await sftp.removeDirectory(tree.path)
            XCTFail("expected RMDIR to fail on non-empty directory")
        } catch let error as SFTPError {
            guard case .status = error else { return XCTFail("unexpected error: \(error)") }
        }

        try await sftp.removeDirectoryRecursively(tree.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
    }

    func testMissingFileErrors() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let sftp = try await SFTPClient.connect(config: testSession())
        defer { sftp.close() }

        do {
            _ = try await sftp.list("/nonexistent-macmoba-\(UUID().uuidString)")
            XCTFail("expected SFTPError")
        } catch let error as SFTPError {
            guard case .status = error else { return XCTFail("unexpected error: \(error)") }
        }
    }
}

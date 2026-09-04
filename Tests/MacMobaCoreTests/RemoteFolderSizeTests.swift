import XCTest
@testable import MacMobaCore

/// Sizing a remote folder before a transfer starts, which is what turns its
/// progress bar from "moving" into "meaning something".
///
/// Against a fake service rather than a server: what matters is the walk —
/// recursion, and which entries count — not the wire.
final class RemoteFolderSizeTests: XCTestCase {
    private final class FakeService: RemoteFileService, @unchecked Sendable {
        var tree: [String: [SFTPItem]] = [:]
        private(set) var listed: [String] = []

        func list(_ path: String) async throws -> [SFTPItem] {
            listed.append(path)
            return tree[path] ?? []
        }

        // Unused here; the protocol needs them.
        func realpath(_ path: String) async throws -> String { path }
        func mkdir(_ path: String) async throws {}
        func removeFile(_ path: String) async throws {}
        func removeDirectoryRecursively(_ path: String) async throws {}
        func rename(_ oldPath: String, to newPath: String) async throws {}
        func download(remotePath: String, to localURL: URL,
                      progress: (@Sendable (UInt64, UInt64?) -> Void)?) async throws {}
        func upload(localURL: URL, to remotePath: String,
                    progress: (@Sendable (UInt64, UInt64?) -> Void)?) async throws {}
        func downloadDirectory(remotePath: String, to localURL: URL,
                               progress: (@Sendable (String, UInt64, UInt64?) -> Void)?) async throws {}
        func uploadDirectory(localURL: URL, to remotePath: String,
                             progress: (@Sendable (String, UInt64, UInt64?) -> Void)?) async throws {}
        func setPermissions(_ path: String, mode: UInt32) async throws {}
        func close() {}
    }

    private func item(_ name: String, size: UInt64, dir: Bool = false,
                      link: Bool = false) -> SFTPItem {
        var perms: UInt32 = 0o100644
        if dir { perms = 0o040755 }
        if link { perms = 0o120777 }
        return SFTPItem(name: name, longname: name,
                        attributes: SFTPAttributes(size: size, permissions: perms))
    }

    func testAddsUpNestedFiles() async throws {
        let service = FakeService()
        service.tree = [
            "/root": [item("a.bin", size: 100), item("sub", size: 0, dir: true)],
            "/root/sub": [item("b.bin", size: 250), item("deep", size: 0, dir: true)],
            "/root/sub/deep": [item("c.bin", size: 7)],
        ]
        let total = try await service.totalSize(ofDirectory: "/root")
        XCTAssertEqual(total, 357)
    }

    /// The copy skips symlinks, so counting them would promise bytes that
    /// never move and leave the bar short of the end.
    func testSkipsSymlinks() async throws {
        let service = FakeService()
        service.tree = ["/root": [item("real", size: 40),
                                  item("link", size: 999, link: true)]]
        let total = try await service.totalSize(ofDirectory: "/root")
        XCTAssertEqual(total, 40)
    }

    func testEmptyFolderIsZero() async throws {
        let service = FakeService()
        service.tree = ["/root": []]
        let total = try await service.totalSize(ofDirectory: "/root")
        XCTAssertEqual(total, 0)
    }

    /// A trailing slash must not produce "//" on the way down.
    func testJoinsPathsWithoutDoublingSlashes() async throws {
        let service = FakeService()
        service.tree = ["/root/": [item("sub", size: 0, dir: true)],
                        "/root/sub": [item("x", size: 5)]]
        let total = try await service.totalSize(ofDirectory: "/root/")
        XCTAssertEqual(total, 5, "listed: \(service.listed)")
    }
}

/// The percentage shown beside the bar.
final class TransferPercentageTests: XCTestCase {
    /// A fraction only exists once the total does — which for a folder is
    /// after the size scan, not when the transfer starts.
    func testFractionNeedsATotal() {
        XCTAssertNil(fraction(done: 500, total: nil))
        XCTAssertNil(fraction(done: 500, total: 0))
        XCTAssertEqual(fraction(done: 500, total: 1000), 0.5)
    }

    /// A total that turns out slightly low must not report 120%.
    func testNeverExceedsWhole() {
        XCTAssertEqual(fraction(done: 1200, total: 1000), 1)
    }

    /// Mirrors SFTPTransfer.fraction, which lives in the app target and
    /// cannot be imported here.
    private func fraction(done: UInt64, total: UInt64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }
}

/// The transfer panel's status line: what it says while a copy runs.
///
/// Mirrors TransferController.progressLine, which lives in the app target.
/// The rules are worth pinning because the panel's whole failure was saying
/// too little — "(1 of 1)" beside a spinner, for as long as a large file took.
final class TransferPanelProgressLineTests: XCTestCase {
    private func line(name: String, completed: Int, total: Int,
                      done: UInt64, fileTotal: UInt64?) -> String {
        guard !name.isEmpty else { return "Working…" }
        var line = name
        if total > 1 { line += " (\(completed + 1) of \(total))" }
        let fraction: Double? = {
            guard let fileTotal, fileTotal > 0 else { return nil }
            return min(1, Double(done) / Double(fileTotal))
        }()
        if let fraction, let fileTotal {
            line += " · \(Int(fraction * 100))% of \(bytes(fileTotal))"
        } else if done > 0 {
            line += " · \(bytes(done))"
        }
        return line
    }

    private func bytes(_ count: UInt64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(count))
    }

    /// The reported case: one file, so no "(1 of 1)" noise — just how far in.
    func testSingleFileShowsPercentNotACount() {
        let text = line(name: "icl_gitrunner.tar.gz", completed: 0, total: 1,
                        done: 5_000_000, fileTotal: 10_000_000)
        XCTAssertTrue(text.contains("50%"), text)
        XCTAssertFalse(text.contains("1 of 1"), "a count of one says nothing: \(text)")
    }

    /// A real queue still says where it is in the queue.
    func testManyFilesKeepTheCount() {
        let text = line(name: "b.txt", completed: 2, total: 9,
                        done: 1, fileTotal: 4)
        XCTAssertTrue(text.contains("(3 of 9)"), text)
        XCTAssertTrue(text.contains("25%"), text)
    }

    /// An unknown size falls back to bytes moved rather than showing nothing.
    func testUnknownSizeStillReportsBytes() {
        let text = line(name: "tree", completed: 0, total: 1,
                        done: 2048, fileTotal: nil)
        XCTAssertFalse(text.contains("%"), text)
        XCTAssertTrue(text.contains("2"), text)
    }

    func testNothingStartedYet() {
        XCTAssertEqual(line(name: "", completed: 0, total: 0, done: 0, fileTotal: nil),
                       "Working…")
    }
}

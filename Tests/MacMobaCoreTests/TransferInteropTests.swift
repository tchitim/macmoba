import XCTest

@testable import MacMobaCore

/// The two-pane transfer, end to end against a real SSH/SFTP server.
///
/// `TransferPlanTests` proves the decisions; this proves the bytes. It drives
/// the same three pieces the UI does — `TransferPlanner.jobs`, `TransferPlan`,
/// and the `RemoteFileService` for each side — so the only thing it does not
/// cover is the SwiftUI wiring around them.
///
/// Start the server with (from TestSupport/):
///
///     sed 's/srv.listen(2299/srv.listen(2405/' ssh-server.js > ssh-xfer.js
///     HOME=/some/scratch/xferRemote node ssh-xfer.js
///
/// The server serves the real filesystem from that HOME, so its files can be
/// checked directly on disk — ground truth rather than a second SFTP call.
final class TransferInteropTests: XCTestCase {
    private static let host = "127.0.0.1"
    private static let port = 2405

    private var localDirectory = URL(fileURLWithPath: "/tmp")
    private var remoteDirectory = ""

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
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func connectClient() async throws -> SFTPClient {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        return try await SFTPClient.connect(
            config: SessionConfig(name: "xfer", host: Self.host, port: Self.port,
                                  username: "test", authType: "password", password: "secret"))
    }

    /// A private directory on each side, so tests cannot see each other's files.
    private func makeScratch(_ client: SFTPClient) async throws {
        let home = try await client.realpath(".")
        remoteDirectory = "\(home)/xfer-test-\(UUID().uuidString.prefix(8))"
        try await client.mkdir(remoteDirectory)
        localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xfer-local-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: localDirectory,
                                                withIntermediateDirectories: true)
    }

    /// Connect, make a scratch directory on each side, run, then clean up —
    /// all AWAITED. `defer { Task { … } }` does not necessarily run before the
    /// test process exits, which left scratch directories on the server.
    private func withScratch(_ body: (SFTPClient) async throws -> Void) async throws {
        let client = try await connectClient()
        try await makeScratch(client)
        do {
            try await body(client)
        } catch {
            await cleanUp(client)
            client.close()
            throw error
        }
        await cleanUp(client)
        client.close()
    }

    private func cleanUp(_ client: SFTPClient) async {
        try? await client.removeDirectoryRecursively(remoteDirectory)
        try? FileManager.default.removeItem(at: localDirectory)
    }

    private func writeLocal(_ name: String, _ contents: String) throws {
        try contents.write(to: localDirectory.appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
    }

    /// The server serves the real filesystem, so its side is readable directly.
    private func remoteContents(_ name: String) throws -> String {
        try String(contentsOfFile: "\(remoteDirectory)/\(name)", encoding: .utf8)
    }

    private func localContents(_ name: String) throws -> String {
        try String(contentsOf: localDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Runs a plan the way `TransferController` does, answering each prompt
    /// from `answers`.
    private func runPlan(_ plan: TransferPlan, direction: TransferDirection,
                         client: SFTPClient, answers: [TransferAnswer]) async throws -> Int {
        var remaining = answers
        var moved = 0
        while true {
            switch plan.nextStep() {
            case .finished:
                XCTAssertTrue(remaining.isEmpty, "not every answer was used")
                return moved
            case .ask:
                guard !remaining.isEmpty else {
                    XCTFail("asked more questions than there were answers")
                    return moved
                }
                plan.answer(remaining.removeFirst())
            case .transfer(let job):
                switch direction {
                case .upload:
                    if job.isDirectory {
                        try await client.uploadDirectory(
                            localURL: URL(fileURLWithPath: job.sourcePath),
                            to: job.destinationPath, progress: nil)
                    } else {
                        try await client.upload(localURL: URL(fileURLWithPath: job.sourcePath),
                                                to: job.destinationPath, progress: nil)
                    }
                case .download:
                    if job.isDirectory {
                        try await client.downloadDirectory(
                            remotePath: job.sourcePath,
                            to: URL(fileURLWithPath: job.destinationPath), progress: nil)
                    } else {
                        try await client.download(remotePath: job.sourcePath,
                                                  to: URL(fileURLWithPath: job.destinationPath),
                                                  progress: nil)
                    }
                }
                moved += 1
            }
        }
    }

    private func uploadPlan(_ client: SFTPClient, select: Set<String>,
                            local: LocalFileService) async throws -> TransferPlan {
        let localItems = try await local.list(localDirectory.path)
        let jobs = TransferPlanner.jobs(selectedNames: select, from: localItems,
                                        sourceDirectory: localDirectory.path,
                                        destinationDirectory: remoteDirectory)
        let existing = Set(try await client.list(remoteDirectory).map(\.name))
        return TransferPlan(jobs: jobs, existingAtDestination: existing)
    }

    // MARK: - Tests

    func testUploadTwoFiles() async throws {
        try await withScratch { client in

            try writeLocal("one.txt", "first")
            try writeLocal("two.txt", "second")
            let plan = try await uploadPlan(client, select: ["one.txt", "two.txt"],
                                            local: LocalFileService())
            let moved = try await runPlan(plan, direction: .upload, client: client, answers: [])

            XCTAssertEqual(moved, 2)
            XCTAssertEqual(try remoteContents("one.txt"), "first")
            XCTAssertEqual(try remoteContents("two.txt"), "second")
        }
    }

    func testDownloadWritesTheServersBytes() async throws {
        try await withScratch { client in

            try "made on the server".write(toFile: "\(remoteDirectory)/from-server.txt",
                                           atomically: true, encoding: .utf8)
            let remoteItems = try await client.list(remoteDirectory)
            let jobs = TransferPlanner.jobs(selectedNames: ["from-server.txt"], from: remoteItems,
                                            sourceDirectory: remoteDirectory,
                                            destinationDirectory: localDirectory.path)
            let plan = TransferPlan(jobs: jobs, existingAtDestination: [])
            let moved = try await runPlan(plan, direction: .download, client: client, answers: [])

            XCTAssertEqual(moved, 1)
            XCTAssertEqual(try localContents("from-server.txt"), "made on the server")
        }
    }

    /// Skip must leave the server's copy untouched — the whole point of asking.
    func testSkipKeepsTheServersVersion() async throws {
        try await withScratch { client in

            try "REMOTE".write(toFile: "\(remoteDirectory)/clash.txt",
                               atomically: true, encoding: .utf8)
            try writeLocal("clash.txt", "LOCAL")
            try writeLocal("fresh.txt", "new file")

            let plan = try await uploadPlan(client, select: ["clash.txt", "fresh.txt"],
                                            local: LocalFileService())
            XCTAssertEqual(plan.conflictCount, 1)
            let moved = try await runPlan(plan, direction: .upload, client: client, answers: [.skip])

            XCTAssertEqual(moved, 1, "only the file with no conflict")
            XCTAssertEqual(try remoteContents("clash.txt"), "REMOTE", "skip must not overwrite")
            XCTAssertEqual(try remoteContents("fresh.txt"), "new file")
        }
    }

    func testReplaceWritesTheLocalVersion() async throws {
        try await withScratch { client in

            try "REMOTE".write(toFile: "\(remoteDirectory)/clash.txt",
                               atomically: true, encoding: .utf8)
            try writeLocal("clash.txt", "LOCAL")

            let plan = try await uploadPlan(client, select: ["clash.txt"], local: LocalFileService())
            _ = try await runPlan(plan, direction: .upload, client: client, answers: [.overwrite])

            XCTAssertEqual(try remoteContents("clash.txt"), "LOCAL")
        }
    }

    /// One "Replace All" must answer for every later clash, and for those only.
    func testReplaceAllAnswersTheRestWithOneClick() async throws {
        try await withScratch { client in

            for name in ["a.txt", "b.txt", "c.txt"] {
                try "REMOTE".write(toFile: "\(remoteDirectory)/\(name)",
                                   atomically: true, encoding: .utf8)
                try writeLocal(name, "LOCAL-\(name)")
            }

            let plan = try await uploadPlan(client, select: ["a.txt", "b.txt", "c.txt"],
                                            local: LocalFileService())
            XCTAssertEqual(plan.conflictCount, 3)
            // A single answer, not three.
            let moved = try await runPlan(plan, direction: .upload, client: client,
                                          answers: [.overwriteAll])

            XCTAssertEqual(moved, 3)
            for name in ["a.txt", "b.txt", "c.txt"] {
                XCTAssertEqual(try remoteContents(name), "LOCAL-\(name)")
            }
        }
    }

    func testSkipAllLeavesEveryClashAloneButStillSendsTheRest() async throws {
        try await withScratch { client in

            for name in ["a.txt", "b.txt"] {
                try "REMOTE".write(toFile: "\(remoteDirectory)/\(name)",
                                   atomically: true, encoding: .utf8)
                try writeLocal(name, "LOCAL")
            }
            try writeLocal("new.txt", "brand new")

            let plan = try await uploadPlan(client, select: ["a.txt", "b.txt", "new.txt"],
                                            local: LocalFileService())
            let moved = try await runPlan(plan, direction: .upload, client: client,
                                          answers: [.skipAll])

            XCTAssertEqual(moved, 1)
            XCTAssertEqual(try remoteContents("a.txt"), "REMOTE")
            XCTAssertEqual(try remoteContents("b.txt"), "REMOTE")
            XCTAssertEqual(try remoteContents("new.txt"), "brand new")
        }
    }

    /// A folder is one job; its contents go with it.
    func testUploadingAFolderTakesItsContents() async throws {
        try await withScratch { client in

            let folder = localDirectory.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "inside".write(to: folder.appendingPathComponent("inner.txt"),
                               atomically: true, encoding: .utf8)

            let plan = try await uploadPlan(client, select: ["tree"], local: LocalFileService())
            let moved = try await runPlan(plan, direction: .upload, client: client, answers: [])

            XCTAssertEqual(moved, 1)
            XCTAssertEqual(try String(contentsOfFile: "\(remoteDirectory)/tree/inner.txt",
                                      encoding: .utf8), "inside")
        }
    }

    /// Binary content must survive both directions unchanged.
    func testRoundTripIsByteIdentical() async throws {
        try await withScratch { client in

            var bytes = Data([0x00, 0x0D, 0x0A, 0xFF, 0x1A])
            bytes.append(contentsOf: (0...255).map { UInt8($0) })
            try bytes.write(to: localDirectory.appendingPathComponent("blob.bin"))

            let up = try await uploadPlan(client, select: ["blob.bin"], local: LocalFileService())
            _ = try await runPlan(up, direction: .upload, client: client, answers: [])

            let back = localDirectory.appendingPathComponent("returned.bin")
            try await client.download(remotePath: "\(remoteDirectory)/blob.bin",
                                      to: back, progress: nil)
            XCTAssertEqual(try Data(contentsOf: back), bytes)
        }
    }

    /// The local side is a `RemoteFileService` too, and the panes are built on
    /// that: if it listed differently the two sides would disagree about what
    /// is a folder.
    func testLocalListingLooksLikeARemoteOne() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-list-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "x".write(to: directory.appendingPathComponent("file.txt"),
                      atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder"), withIntermediateDirectories: true)

        let items = try await LocalFileService().list(directory.path)
        let file = try XCTUnwrap(items.first { $0.name == "file.txt" })
        let folder = try XCTUnwrap(items.first { $0.name == "folder" })
        XCTAssertFalse(file.isDirectory)
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(file.size, 1)
    }
}

/// One-way sync against the real server.
///
/// The comparison rules are unit-tested in `SyncPlannerTests`; this walks two
/// real trees the way the controller does and checks the files that come out
/// the other end — including that running it twice copies nothing the second
/// time, which is the property a sync lives or dies by.
extension TransferInteropTests {
    /// The controller's loop, minus the UI: compare, copy, descend.
    private func performSync(from source: RemoteFileService, sourceRoot: String,
                             to destination: RemoteFileService,
                             destinationRoot: String) async throws -> Int {
        var copied = 0
        var pending: [(String, String)] = [(sourceRoot, destinationRoot)]
        while let (from, to) = pending.first {
            pending.removeFirst()
            let sourceItems = try await source.list(from)
            let destinationItems = (try? await destination.list(to)) ?? []
            let comparison = SyncPlanner.compare(source: sourceItems,
                                                 destination: destinationItems)
            for file in comparison.filesToCopy {
                try await copy(name: file.name, from: from, to: to,
                               source: source, destination: destination, isDirectory: false)
                copied += 1
            }
            for folder in comparison.directoriesToCopyWhole {
                try await copy(name: folder.name, from: from, to: to,
                               source: source, destination: destination, isDirectory: true)
                copied += 1
            }
            for folder in comparison.directoriesToDescend {
                pending.append((FTPProtocol.join(from, folder.name),
                                FTPProtocol.join(to, folder.name)))
            }
        }
        return copied
    }

    private func copy(name: String, from: String, to: String,
                      source: RemoteFileService, destination: RemoteFileService,
                      isDirectory: Bool) async throws {
        let sourcePath = FTPProtocol.join(from, name)
        let destinationPath = FTPProtocol.join(to, name)
        // One side is always this Mac, so a copy is an upload or a download.
        if source is LocalFileService {
            if isDirectory {
                try await destination.uploadDirectory(
                    localURL: URL(fileURLWithPath: sourcePath), to: destinationPath,
                    progress: nil)
            } else {
                try await destination.upload(localURL: URL(fileURLWithPath: sourcePath),
                                             to: destinationPath, progress: nil)
            }
        } else {
            if isDirectory {
                try await source.downloadDirectory(
                    remotePath: sourcePath, to: URL(fileURLWithPath: destinationPath),
                    progress: nil)
            } else {
                try await source.download(remotePath: sourcePath,
                                          to: URL(fileURLWithPath: destinationPath),
                                          progress: nil)
            }
        }
    }

    func testSyncCopiesATreeAndThenHasNothingLeftToDo() async throws {
        try await withScratch { client in
            let local = LocalFileService()
            try self.writeLocal("top.txt", "top level")
            let sub = self.localDirectory.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try "nested".write(to: sub.appendingPathComponent("inner.txt"),
                               atomically: true, encoding: .utf8)

            let first = try await self.performSync(from: local,
                                                   sourceRoot: self.localDirectory.path,
                                                   to: client,
                                                   destinationRoot: self.remoteDirectory)
            XCTAssertEqual(first, 2, "one file and one folder")
            XCTAssertEqual(try self.remoteContents("top.txt"), "top level")
            XCTAssertEqual(try String(contentsOfFile: "\(self.remoteDirectory)/sub/inner.txt",
                                      encoding: .utf8), "nested")

            // The property that makes it a sync rather than a copy.
            let second = try await self.performSync(from: local,
                                                    sourceRoot: self.localDirectory.path,
                                                    to: client,
                                                    destinationRoot: self.remoteDirectory)
            XCTAssertEqual(second, 0, "a second run must copy nothing")
        }
    }

    func testSyncCopiesOnlyWhatChanged() async throws {
        try await withScratch { client in
            let local = LocalFileService()
            try self.writeLocal("a.txt", "one")
            try self.writeLocal("b.txt", "two")
            _ = try await self.performSync(from: local, sourceRoot: self.localDirectory.path,
                                           to: client, destinationRoot: self.remoteDirectory)

            // Change one file; its size and time both move.
            try self.writeLocal("b.txt", "two, but edited")
            let copied = try await self.performSync(from: local,
                                                    sourceRoot: self.localDirectory.path,
                                                    to: client,
                                                    destinationRoot: self.remoteDirectory)
            XCTAssertEqual(copied, 1, "only the edited file")
            XCTAssertEqual(try self.remoteContents("b.txt"), "two, but edited")
            XCTAssertEqual(try self.remoteContents("a.txt"), "one")
        }
    }

    /// Sync never removes anything at the destination.
    func testSyncLeavesExtraFilesAtTheDestinationAlone() async throws {
        try await withScratch { client in
            let local = LocalFileService()
            try "only on the server".write(toFile: "\(self.remoteDirectory)/theirs.txt",
                                           atomically: true, encoding: .utf8)
            try self.writeLocal("mine.txt", "from the Mac")

            _ = try await self.performSync(from: local, sourceRoot: self.localDirectory.path,
                                           to: client, destinationRoot: self.remoteDirectory)

            XCTAssertEqual(try self.remoteContents("theirs.txt"), "only on the server",
                           "a sync must not delete what it did not put there")
            XCTAssertEqual(try self.remoteContents("mine.txt"), "from the Mac")
        }
    }

    /// The other direction, pulling from the server.
    func testSyncFromTheServerToThisMac() async throws {
        try await withScratch { client in
            let local = LocalFileService()
            try "server side".write(toFile: "\(self.remoteDirectory)/down.txt",
                                    atomically: true, encoding: .utf8)

            let copied = try await self.performSync(from: client,
                                                    sourceRoot: self.remoteDirectory,
                                                    to: local,
                                                    destinationRoot: self.localDirectory.path)
            XCTAssertEqual(copied, 1)
            XCTAssertEqual(try self.localContents("down.txt"), "server side")
        }
    }
}

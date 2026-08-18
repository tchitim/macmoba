import XCTest

@testable import MacMobaCore

/// One-way sync: what gets copied, and — more importantly — what does not.
final class SyncPlannerTests: XCTestCase {
    private func file(_ name: String, size: UInt64 = 100, modified: UInt32 = 1_000) -> SFTPItem {
        var attributes = SFTPAttributes()
        attributes.size = size
        attributes.mtime = modified
        attributes.permissions = 0o100644
        return SFTPItem(name: name, longname: name, attributes: attributes)
    }

    private func folder(_ name: String) -> SFTPItem {
        var attributes = SFTPAttributes()
        attributes.permissions = 0o040755
        return SFTPItem(name: name, longname: name, attributes: attributes)
    }

    private func symlink(_ name: String) -> SFTPItem {
        var attributes = SFTPAttributes()
        attributes.permissions = 0o120777
        return SFTPItem(name: name, longname: name, attributes: attributes)
    }

    func testMissingFilesAreCopied() {
        let result = SyncPlanner.compare(source: [file("new.txt")], destination: [])
        XCTAssertEqual(result.filesToCopy.map(\.name), ["new.txt"])
        XCTAssertTrue(result.unchangedFiles.isEmpty)
    }

    /// The point of a sync: running it twice must not copy anything the second
    /// time.
    func testIdenticalFilesAreLeftAlone() {
        let same = file("same.txt", size: 100, modified: 1_000)
        let result = SyncPlanner.compare(source: [same], destination: [same])
        XCTAssertTrue(result.filesToCopy.isEmpty)
        XCTAssertEqual(result.unchangedFiles.map(\.name), ["same.txt"])
        XCTAssertTrue(result.isEmpty, "nothing to do")
    }

    func testADifferentSizeIsAlwaysCopied() {
        let result = SyncPlanner.compare(
            source: [file("a.txt", size: 200, modified: 1_000)],
            destination: [file("a.txt", size: 100, modified: 1_000)])
        XCTAssertEqual(result.filesToCopy.map(\.name), ["a.txt"])
    }

    func testANewerSourceIsCopied() {
        let result = SyncPlanner.compare(
            source: [file("a.txt", modified: 5_000)],
            destination: [file("a.txt", modified: 1_000)])
        XCTAssertEqual(result.filesToCopy.map(\.name), ["a.txt"])
        XCTAssertTrue(result.replacingNewer.isEmpty)
    }

    /// Clocks are never exactly aligned, and SFTP reports whole seconds while a
    /// local file has sub-second precision. Without a tolerance every run would
    /// copy the same unchanged files again.
    func testASecondOfClockDriftDoesNotTriggerACopy() {
        let result = SyncPlanner.compare(
            source: [file("a.txt", modified: 1_001)],
            destination: [file("a.txt", modified: 1_000)])
        XCTAssertTrue(result.filesToCopy.isEmpty, "one second is drift, not a change")
        XCTAssertEqual(result.unchangedFiles.count, 1)
    }

    func testBeyondTheToleranceItIsACopy() {
        let result = SyncPlanner.compare(
            source: [file("a.txt", modified: 1_010)],
            destination: [file("a.txt", modified: 1_000)])
        XCTAssertEqual(result.filesToCopy.map(\.name), ["a.txt"])
    }

    /// A same-size file that is OLDER here is not copied: it would be a
    /// silent downgrade of the destination.
    func testAnOlderSourceOfTheSameSizeIsNotCopied() {
        let result = SyncPlanner.compare(
            source: [file("a.txt", size: 100, modified: 1_000)],
            destination: [file("a.txt", size: 100, modified: 9_000)])
        XCTAssertTrue(result.filesToCopy.isEmpty)
    }

    /// When the size differs it does get copied — but the user is warned,
    /// because the destination copy is more recent.
    func testReplacingANewerFileIsFlagged() {
        let result = SyncPlanner.compare(
            source: [file("a.txt", size: 200, modified: 1_000)],
            destination: [file("a.txt", size: 100, modified: 9_000)])
        XCTAssertEqual(result.filesToCopy.map(\.name), ["a.txt"])
        XCTAssertEqual(result.replacingNewer, ["a.txt"])
        XCTAssertTrue(SyncPlanner.summary(result).contains("NEWER"))
    }

    // MARK: Directories

    func testAMissingFolderIsCopiedWholeAndACommonOneIsDescendedInto() {
        let result = SyncPlanner.compare(
            source: [folder("fresh"), folder("shared")],
            destination: [folder("shared")])
        XCTAssertEqual(result.directoriesToCopyWhole.map(\.name), ["fresh"])
        XCTAssertEqual(result.directoriesToDescend.map(\.name), ["shared"])
    }

    /// A file on one side and a folder on the other is never guessed at: the
    /// copy would fail, or worse, succeed by destroying one of them.
    func testAFileAgainstAFolderIsSkippedAndReported() {
        let fileVersusFolder = SyncPlanner.compare(
            source: [file("thing")], destination: [folder("thing")])
        XCTAssertEqual(fileVersusFolder.typeConflicts, ["thing"])
        XCTAssertTrue(fileVersusFolder.filesToCopy.isEmpty)

        let folderVersusFile = SyncPlanner.compare(
            source: [folder("thing")], destination: [file("thing")])
        XCTAssertEqual(folderVersusFile.typeConflicts, ["thing"])
        XCTAssertTrue(folderVersusFile.directoriesToCopyWhole.isEmpty)
    }

    func testSymlinksAreIgnoredEntirely() {
        let result = SyncPlanner.compare(source: [symlink("link"), file("real.txt")],
                                         destination: [])
        XCTAssertEqual(result.filesToCopy.map(\.name), ["real.txt"])
        XCTAssertTrue(result.typeConflicts.isEmpty)
    }

    /// Nothing at the destination is ever removed. A file that exists only
    /// there simply does not appear in the plan.
    func testFilesOnlyAtTheDestinationAreUntouched() {
        let result = SyncPlanner.compare(source: [file("a.txt")],
                                         destination: [file("a.txt"), file("theirs.txt")])
        XCTAssertFalse(result.filesToCopy.contains { $0.name == "theirs.txt" })
        XCTAssertFalse(result.unchangedFiles.contains { $0.name == "theirs.txt" })
        XCTAssertTrue(result.replacingNewer.isEmpty)
    }

    func testEmptySourceMeansNothingToDo() {
        let result = SyncPlanner.compare(source: [], destination: [file("a.txt")])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Summary

    func testSummaryCountsWhatWillHappen() {
        let result = SyncPlanner.compare(
            source: [file("a.txt"), file("b.txt", modified: 9_000), folder("newdir"),
                     file("same.txt", size: 5, modified: 100)],
            destination: [file("b.txt", modified: 1_000),
                          file("same.txt", size: 5, modified: 100)])
        let summary = SyncPlanner.summary(result)
        XCTAssertTrue(summary.contains("2 files"), summary)
        XCTAssertTrue(summary.contains("1 new folder"), summary)
        XCTAssertTrue(summary.contains("1 already up to date"), summary)
    }

    func testSummaryOfASingleFileIsNotPluralised() {
        let result = SyncPlanner.compare(source: [file("only.txt")], destination: [])
        XCTAssertTrue(SyncPlanner.summary(result).hasPrefix("Copy 1 file."),
                      SyncPlanner.summary(result))
    }
}

import XCTest

@testable import MacMobaCore

final class FileSortTests: XCTestCase {
    private func item(_ name: String, directory: Bool = false,
                      size: UInt64 = 0, modified: UInt32? = nil) -> SFTPItem {
        var attributes = SFTPAttributes()
        attributes.size = size
        attributes.mtime = modified
        attributes.permissions = directory ? 0o040755 : 0o100644
        return SFTPItem(name: name, longname: name, attributes: attributes)
    }

    private func names(_ items: [SFTPItem]) -> [String] { items.map(\.name) }

    // MARK: Name

    /// The Finder's comparison, which is number-aware. A plain string sort puts
    /// file10 before file2, which looks broken to anyone with numbered files.
    func testNamesSortLikeTheFinder() {
        let items = [item("file10.txt"), item("file2.txt"), item("File1.txt")]
        XCTAssertEqual(names(FileSort.sort(items, by: .name, ascending: true)),
                       ["File1.txt", "file2.txt", "file10.txt"])
    }

    func testDescendingReversesIt() {
        let items = [item("a"), item("b"), item("c")]
        XCTAssertEqual(names(FileSort.sort(items, by: .name, ascending: false)),
                       ["c", "b", "a"])
    }

    func testFoldersStayOnTopWhicheverWay() {
        let items = [item("zebra.txt"), item("alpha", directory: true), item("beta.txt")]
        XCTAssertEqual(names(FileSort.sort(items, by: .name, ascending: true)),
                       ["alpha", "beta.txt", "zebra.txt"])
        XCTAssertEqual(names(FileSort.sort(items, by: .name, ascending: false)).first,
                       "alpha", "a folder leads even when the order is reversed")
    }

    func testFoldersCanBeMixedIn() {
        let items = [item("b.txt"), item("a", directory: true)]
        XCTAssertEqual(names(FileSort.sort(items, by: .name, ascending: true,
                                           foldersFirst: false)),
                       ["a", "b.txt"])
    }

    // MARK: Modified

    func testNewestFirst() {
        let items = [item("old.txt", modified: 1_000),
                     item("newest.txt", modified: 3_000),
                     item("middle.txt", modified: 2_000)]
        XCTAssertEqual(names(FileSort.sort(items, by: .modified, ascending: false)),
                       ["newest.txt", "middle.txt", "old.txt"])
    }

    /// A server that reports no time must not float to the top of a
    /// newest-first list as though it were the most recent thing there.
    func testAMissingTimeSortsAsOldest() {
        let items = [item("dated.txt", modified: 1_000), item("undated.txt")]
        XCTAssertEqual(names(FileSort.sort(items, by: .modified, ascending: false)),
                       ["dated.txt", "undated.txt"])
    }

    // MARK: Size

    func testBiggestFirst() {
        let items = [item("small.txt", size: 10), item("huge.bin", size: 10_000),
                     item("medium.txt", size: 500)]
        XCTAssertEqual(names(FileSort.sort(items, by: .size, ascending: false)),
                       ["huge.bin", "medium.txt", "small.txt"])
    }

    /// A directory's reported size is a block count, not the size of its
    /// contents, so ordering folders by it would be meaningless — they fall
    /// back to name.
    func testFoldersOrderByNameWhenSortingBySize() {
        let items = [item("zed", directory: true, size: 4096),
                     item("abc", directory: true, size: 8192)]
        XCTAssertEqual(names(FileSort.sort(items, by: .size, ascending: false)),
                       ["abc", "zed"])
    }

    // MARK: Kind

    func testKindGroupsByExtension() {
        let items = [item("b.txt"), item("a.zip"), item("c.txt")]
        XCTAssertEqual(names(FileSort.sort(items, by: .kind, ascending: true)),
                       ["b.txt", "c.txt", "a.zip"])
    }

    /// A dotfile is named that, it does not have a kind.
    func testLeadingDotIsNotAnExtension() {
        XCTAssertEqual(FileSort.fileExtension(".bashrc"), "")
        XCTAssertEqual(FileSort.fileExtension("archive.tar.gz"), "gz")
        XCTAssertEqual(FileSort.fileExtension("noextension"), "")
        XCTAssertEqual(FileSort.fileExtension("UPPER.TXT"), "txt")
    }

    // MARK: Stability

    /// Every order has to be total. If two equal items can compare both ways,
    /// the list quietly reshuffles on each refresh and the selection appears
    /// to jump to another row.
    func testEqualItemsKeepAFixedOrderAcrossSorts() {
        let items = [item("b.txt", size: 100), item("a.txt", size: 100),
                     item("c.txt", size: 100)]
        let first = names(FileSort.sort(items, by: .size, ascending: false))
        let again = names(FileSort.sort(items.reversed(), by: .size, ascending: false))
        XCTAssertEqual(first, ["a.txt", "b.txt", "c.txt"], "ties break on name")
        XCTAssertEqual(first, again, "the input order must not change the result")
    }

    func testTiesBreakAscendingEvenWhenTheSortIsDescending() {
        let items = [item("b.txt", modified: 5), item("a.txt", modified: 5)]
        XCTAssertEqual(names(FileSort.sort(items, by: .modified, ascending: false)),
                       ["a.txt", "b.txt"])
    }

    func testEmptyAndSingleListsAreFine() {
        XCTAssertTrue(FileSort.sort([], by: .name, ascending: true).isEmpty)
        XCTAssertEqual(names(FileSort.sort([item("only.txt")], by: .size, ascending: false)),
                       ["only.txt"])
    }

    /// The default direction is per key: nobody picks "sort by date" to see
    /// the oldest thing first.
    func testDefaultDirectionMatchesWhatTheKeyIsFor() {
        XCTAssertFalse(FileSortKey.name.prefersDescending)
        XCTAssertFalse(FileSortKey.kind.prefersDescending)
        XCTAssertTrue(FileSortKey.modified.prefersDescending)
        XCTAssertTrue(FileSortKey.size.prefersDescending)
    }
}

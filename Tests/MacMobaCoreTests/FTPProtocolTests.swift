import XCTest

@testable import MacMobaCore

/// FTP's difficulty is entirely in its text: replies that span lines, a passive
/// address encoded as six decimal numbers, and a directory listing that was
/// never standardised. All of it is testable without a socket.
final class FTPReplyTests: XCTestCase {
    func testSingleLineReply() {
        let reply = FTPProtocol.parseReply(["220 Service ready"])
        XCTAssertEqual(reply, FTPProtocol.Reply(code: 220, text: "Service ready"))
    }

    func testIncompleteReplyIsNotAccepted() {
        XCTAssertNil(FTPProtocol.parseReply([]))
        XCTAssertNil(FTPProtocol.parseReply(["22"]))
        XCTAssertNil(FTPProtocol.parseReply(["xyz hello"]))
    }

    /// A block opened with "code-" is only closed by "code ", never by any
    /// other three-digit line.
    func testMultiLineReplyNeedsItsOwnTerminator() {
        let lines = ["211-Features:", " MLST type*;size*;", " UTF8", "211 End"]
        XCTAssertNil(FTPProtocol.parseReply(Array(lines.dropLast())),
                     "an unterminated block must not be treated as complete")
        let reply = FTPProtocol.parseReply(lines)
        XCTAssertEqual(reply?.code, 211)
        XCTAssertEqual(reply?.text, "Features:\n MLST type*;size*;\n UTF8\nEnd")
    }

    /// The trap: a banner line that starts with digits which are NOT the
    /// terminator. Ending the reply there desynchronises every later command.
    func testDigitsInsideABannerDoNotEndTheReply() {
        let lines = ["220-Welcome to", "220-1998 was a good year", "230 not the end either",
                     "220 ready"]
        let reply = FTPProtocol.parseReply(lines)
        XCTAssertEqual(reply?.code, 220)
        XCTAssertTrue(reply?.text.hasSuffix("ready") ?? false)
        XCTAssertTrue(reply?.text.contains("230 not the end either") ?? false,
                      "a different code inside the block is body text, not the terminator")
    }

    func testPositiveAndPreliminary() {
        XCTAssertTrue(FTPProtocol.Reply(code: 226, text: "").isPositive)
        XCTAssertTrue(FTPProtocol.Reply(code: 150, text: "").isPreliminary)
        XCTAssertFalse(FTPProtocol.Reply(code: 550, text: "").isPositive)
        XCTAssertFalse(FTPProtocol.Reply(code: 150, text: "").isPositive)
    }
}

final class FTPPassiveTests: XCTestCase {
    func testPASV() {
        let result = FTPProtocol.parsePASV("Entering Passive Mode (192,168,1,5,195,80)")
        XCTAssertEqual(result?.host, "192.168.1.5")
        XCTAssertEqual(result?.port, 195 * 256 + 80)
    }

    /// Some servers leave out the brackets, and the reply always begins with
    /// its own status code — which must not be mistaken for part of the address.
    func testPASVWithoutBracketsAndWithALeadingCode() {
        let result = FTPProtocol.parsePASV("227 Entering Passive Mode 10,0,0,1,4,1")
        XCTAssertEqual(result?.host, "10.0.0.1")
        XCTAssertEqual(result?.port, 1025)
    }

    func testPASVRejectsOutOfRangeBytes() {
        XCTAssertNil(FTPProtocol.parsePASV("(999,1,1,1,1,1)"))
        XCTAssertNil(FTPProtocol.parsePASV("Entering Passive Mode"))
    }

    func testEPSV() {
        XCTAssertEqual(FTPProtocol.parseEPSV("Entering Extended Passive Mode (|||49152|)"), 49152)
    }

    /// The delimiter is whatever character follows the bracket; it is not
    /// required to be "|".
    func testEPSVWithAnotherDelimiter() {
        XCTAssertEqual(FTPProtocol.parseEPSV("229 EPSV ok (!!!1234!)"), 1234)
    }

    func testEPSVRejectsNonsense() {
        XCTAssertNil(FTPProtocol.parseEPSV("229 no brackets here"))
        XCTAssertNil(FTPProtocol.parseEPSV("229 (|||99999|)"))
    }
}

final class FTPListingTests: XCTestCase {
    // MARK: MLSD

    func testMLSDFile() throws {
        let item = try XCTUnwrap(
            FTPProtocol.parseMLSD("type=file;size=1234;modify=20240102030405; report.txt"))
        XCTAssertEqual(item.name, "report.txt")
        XCTAssertEqual(item.size, 1234)
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.modified?.timeIntervalSince1970, 1_704_164_645)
    }

    func testMLSDDirectory() throws {
        let item = try XCTUnwrap(FTPProtocol.parseMLSD("type=dir;sizd=4096; uploads"))
        XCTAssertTrue(item.isDirectory, "the browser decides folder-ness from the mode bits")
        XCTAssertEqual(item.name, "uploads")
    }

    /// cdir/pdir are "." and ".." — listing them would put the current folder
    /// inside itself.
    func testMLSDSkipsSelfAndParent() {
        XCTAssertNil(FTPProtocol.parseMLSD("type=cdir;modify=20240102030405; /pub"))
        XCTAssertNil(FTPProtocol.parseMLSD("type=pdir; .."))
        XCTAssertNil(FTPProtocol.parseMLSD("type=dir; ."))
    }

    /// The name is everything after the first space, so spaces and semicolons
    /// inside it survive.
    func testMLSDNameKeepsSpacesAndSemicolons() throws {
        let item = try XCTUnwrap(
            FTPProtocol.parseMLSD("type=file;size=1; My Report; final.txt"))
        XCTAssertEqual(item.name, "My Report; final.txt")
    }

    func testMLSDFactsAreCaseInsensitive() throws {
        let item = try XCTUnwrap(FTPProtocol.parseMLSD("Type=DIR;Size=10; Docs"))
        XCTAssertTrue(item.isDirectory)
    }

    func testMLSDUnixMode() throws {
        let item = try XCTUnwrap(
            FTPProtocol.parseMLSD("type=file;size=0;UNIX.mode=0755; run.sh"))
        XCTAssertEqual(item.attributes.permissions! & 0o7777, 0o755)
        XCTAssertFalse(item.isDirectory)
    }

    func testMLSDSymlink() throws {
        let item = try XCTUnwrap(FTPProtocol.parseMLSD("type=OS.unix=slink:/tmp; scratch"))
        XCTAssertTrue(item.isSymlink)
    }

    // MARK: Unix LIST

    func testUnixListingFile() throws {
        let line = "-rw-r--r--   1 owner group      123 Jan  2  2023 file.txt"
        let item = try XCTUnwrap(FTPProtocol.parseUnixListing(line))
        XCTAssertEqual(item.name, "file.txt")
        XCTAssertEqual(item.size, 123)
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.attributes.permissions! & 0o7777, 0o644)
    }

    func testUnixListingDirectory() throws {
        let line = "drwxr-xr-x   2 owner group     4096 Jan  2 03:04 uploads"
        let item = try XCTUnwrap(FTPProtocol.parseUnixListing(line))
        XCTAssertTrue(item.isDirectory)
        XCTAssertEqual(item.attributes.permissions! & 0o7777, 0o755)
    }

    /// Splitting on whitespace and taking the last field loses the rest of the
    /// name — and names with spaces are common.
    func testUnixListingKeepsSpacesInNames() throws {
        let line = "-rw-r--r--   1 owner group      123 Jan  2  2023 My Holiday Photos.zip"
        let item = try XCTUnwrap(FTPProtocol.parseUnixListing(line))
        XCTAssertEqual(item.name, "My Holiday Photos.zip")
    }

    func testUnixListingSymlinkKeepsOnlyItsOwnName() throws {
        let line = "lrwxrwxrwx 1 owner group 7 Jan  2  2023 latest -> v2.tar"
        let item = try XCTUnwrap(FTPProtocol.parseUnixListing(line))
        XCTAssertEqual(item.name, "latest")
        XCTAssertTrue(item.isSymlink)
    }

    func testUnixListingSkipsTotalAndDotEntries() {
        XCTAssertNil(FTPProtocol.parseUnixListing("total 20"))
        XCTAssertNil(FTPProtocol.parseUnixListing("drwxr-xr-x 2 o g 4096 Jan  2  2023 ."))
        XCTAssertNil(FTPProtocol.parseUnixListing("drwxr-xr-x 2 o g 4096 Jan  2  2023 .."))
    }

    /// A DOS-style listing is not guessed at: a wrong size or type is worse
    /// than a row that is missing.
    func testUnknownListingFormatIsSkipped() {
        XCTAssertNil(FTPProtocol.parseUnixListing("01-02-24  03:04PM       <DIR>          uploads"))
    }

    func testSetuidAndStickyBits() throws {
        let sticky = try XCTUnwrap(
            FTPProtocol.parseUnixListing("drwxrwxrwt 2 o g 4096 Jan  2  2023 tmp"))
        XCTAssertEqual(sticky.attributes.permissions! & 0o7777, 0o1777)
        let setuid = try XCTUnwrap(
            FTPProtocol.parseUnixListing("-rwsr-xr-x 1 o g 100 Jan  2  2023 su"))
        XCTAssertEqual(setuid.attributes.permissions! & 0o7777, 0o4755)
    }

    /// `ls` omits the year for recent files. A date more than a day ahead of
    /// now is therefore last year's — without that rule, every December file
    /// looks like it is from the future for the whole of January.
    func testAListingWithNoYearIsNotDatedInTheFuture() throws {
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: components)!

        let december = try XCTUnwrap(FTPProtocol.parseUnixListing(
            "-rw-r--r-- 1 o g 1 Dec 20 09:00 old.txt", now: now))
        let date = try XCTUnwrap(december.modified)
        XCTAssertLessThan(date, now, "December seen from January belongs to the previous year")
        XCTAssertEqual(calendar.component(.year, from: date), 2023)

        let january = try XCTUnwrap(FTPProtocol.parseUnixListing(
            "-rw-r--r-- 1 o g 1 Jan  4 09:00 new.txt", now: now))
        XCTAssertEqual(calendar.component(.year, from: try XCTUnwrap(january.modified)), 2024)
    }

    func testWholeListingIgnoresBlankAndBrokenLines() {
        let text = "total 8\r\n-rw-r--r-- 1 o g 1 Jan  2  2023 a.txt\r\n\r\ngarbage\r\n"
        let items = FTPProtocol.parseListing(text, isMLSD: false)
        XCTAssertEqual(items.map(\.name), ["a.txt"])
    }

    func testWholeMLSDListing() {
        let text = "type=cdir; /\r\ntype=dir; sub\r\ntype=file;size=5; a.txt\r\n"
        let items = FTPProtocol.parseListing(text, isMLSD: true)
        XCTAssertEqual(items.map(\.name), ["sub", "a.txt"])
        XCTAssertTrue(items[0].isDirectory)
    }
}

final class FTPFeatureTests: XCTestCase {
    func testFEATListing() {
        let text = "Features:\n MLST type*;size*;modify*;\n MLSD\n UTF8\n AUTH TLS\nEnd"
        let features = FTPProtocol.parseFEAT(text)
        XCTAssertTrue(features.contains("MLSD"))
        XCTAssertTrue(features.contains("UTF8"))
        XCTAssertTrue(features.contains("AUTH"))
        XCTAssertFalse(features.contains("END"))
        XCTAssertFalse(features.contains("FEATURES:"))
    }

    func testPathJoinMatchesTheSFTPBrowser() {
        XCTAssertEqual(FTPProtocol.join("/", "a.txt"), "/a.txt")
        XCTAssertEqual(FTPProtocol.join("/pub", "a.txt"), "/pub/a.txt")
        XCTAssertEqual(FTPProtocol.join("/pub/", "a.txt"), "/pub/a.txt")
        XCTAssertEqual(FTPProtocol.join("", "a.txt"), "/a.txt")
    }
}

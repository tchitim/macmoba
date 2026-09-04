import XCTest
@testable import MacMobaCore

/// What the seven-day sweep will and will not delete.
///
/// Pure, so it runs without a server — and worth testing precisely because it
/// deletes files on someone else's machine, where being slightly too eager is
/// not recoverable.
final class RemotePasteRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func name(daysAgo: Double) -> String {
        "paste-\(Int(now.timeIntervalSince1970 - daysAgo * 86_400)).png"
    }

    func testDeletesOnlyBeyondTheWindow() {
        let old = name(daysAgo: 8)
        let fresh = name(daysAgo: 6)
        let expired = RemotePasteRetention.expired(names: [old, fresh], now: now)
        XCTAssertEqual(expired, [old])
    }

    /// The boundary is the window itself, so a file exactly seven days old
    /// survives. Ties go to keeping the file.
    func testExactlySevenDaysIsKept() {
        XCTAssertTrue(RemotePasteRetention.expired(names: [name(daysAgo: 7)], now: now).isEmpty)
    }

    /// Anything that is not one of ours is untouchable, however old. The
    /// directory is the user's, not this feature's.
    func testLeavesForeignFilesAlone() {
        let foreign = ["notes.txt", "paste-old.png", "paste-123.jpg", "screenshot.png",
                       "paste-.png", "prefix-paste-1.png", ".hidden"]
        XCTAssertTrue(RemotePasteRetention.expired(names: foreign, now: now).isEmpty)
    }

    /// A name shaped like ours but with an unreadable stamp is kept rather
    /// than guessed about.
    func testUnparseableStampIsKept() {
        XCTAssertTrue(RemotePasteRetention.expired(names: ["paste-12x34.png"], now: now).isEmpty)
    }

    /// A stamp from the future is not "very old"; a clock skew must not
    /// trigger a delete.
    func testFutureStampIsKept() {
        let ahead = "paste-\(Int(now.timeIntervalSince1970 + 86_400)).png"
        XCTAssertTrue(RemotePasteRetention.expired(names: [ahead], now: now).isEmpty)
    }

    func testWindowIsSevenDays() {
        XCTAssertEqual(RemotePasteRetention.defaultMaxAge, 7 * 24 * 60 * 60)
    }
}

// MARK: - Per-session folders

/// The slug becomes a path segment on a remote machine, so what it refuses
/// matters more than what it keeps.
final class RemotePasteFolderTests: XCTestCase {
    func testKeepsOrdinaryNames() {
        XCTAssertEqual(RemotePasteFolder.slug(for: "haoji"), "haoji")
        XCTAssertEqual(RemotePasteFolder.slug(for: "macmoba-swift"), "macmoba-swift")
        XCTAssertEqual(RemotePasteFolder.slug(for: "web_01.prod"), "web_01.prod")
    }

    func testTwoSessionsOnOneHostDoNotShare() {
        XCTAssertNotEqual(RemotePasteFolder.slug(for: "haoji"),
                          RemotePasteFolder.slug(for: "macmoba-swift"))
    }

    /// Nothing may escape the folder it is given.
    func testCannotTraverseOrSplitThePath() {
        for hostile in ["../../etc", "a/b", "..", "./.", "~/x", "a\\b"] {
            let slug = RemotePasteFolder.slug(for: hostile)
            XCTAssertFalse(slug.contains("/"), "\(hostile) produced \(slug)")
            XCTAssertFalse(slug.contains(".."), "\(hostile) produced \(slug)")
            XCTAssertFalse(slug.hasPrefix("."), "\(hostile) produced \(slug)")
        }
    }

    /// Spaces and quotes cannot reach a path, so a name never has to be
    /// escaped later.
    func testAwkwardCharactersBecomeDashes() {
        XCTAssertEqual(RemotePasteFolder.slug(for: "my server"), "my-server")
        XCTAssertEqual(RemotePasteFolder.slug(for: "a  b"), "a-b")
        XCTAssertFalse(RemotePasteFolder.slug(for: "it's \"prod\"").contains("\""))
    }

    /// A name with nothing usable in it still has to yield a segment, or the
    /// path would end in a slash.
    func testNamesThatSurviveNothingStillGiveASegment() {
        XCTAssertEqual(RemotePasteFolder.slug(for: ""), "session")
        XCTAssertEqual(RemotePasteFolder.slug(for: "///"), "session")
        XCTAssertEqual(RemotePasteFolder.slug(for: "..."), "session")
    }

    func testLongNamesAreBounded() {
        XCTAssertLessThanOrEqual(RemotePasteFolder.slug(for: String(repeating: "a", count: 500)).count, 64)
    }

    /// CJK session names are common here and are letters, so they are kept
    /// rather than mangled into a row of dashes.
    func testUnicodeLettersSurvive() {
        XCTAssertEqual(RemotePasteFolder.slug(for: "測試機"), "測試機")
    }
}

extension RemotePasteRetentionTests {
    /// The sweep must not delete the upload it was called to tidy up after,
    /// whatever its name would otherwise say about its age.
    func testKeptNameIsNeverExpired() {
        let ancient = "paste-1.png"
        XCTAssertEqual(RemotePasteRetention.expired(names: [ancient], now: now), [ancient],
                       "the rule itself does consider it expired")
        // The guard lives in sweepExpired, which needs a client; this records
        // that the two disagree on purpose, so the filter is not mistaken for
        // redundancy later.
    }
}

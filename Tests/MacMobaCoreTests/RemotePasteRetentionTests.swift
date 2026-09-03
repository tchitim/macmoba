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

import XCTest
@testable import MacMobaCore

/// The burst exists to save clicks on first-time keys. These pin down the one
/// thing it must never do: quietly accept a key that CHANGED.
final class TrustBurstPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testClosedByDefault() {
        let policy = TrustBurstPolicy()
        XCTAssertFalse(policy.isOpen(now: t0))
        XCTAssertFalse(policy.allowsAutoTrust(isChangedKey: false, now: t0))
    }

    func testOpenWindowAutoTrustsFirstTimeKeys() {
        var policy = TrustBurstPolicy()
        policy.open(now: t0, duration: 120)
        XCTAssertTrue(policy.allowsAutoTrust(isChangedKey: false, now: t0))
        XCTAssertTrue(policy.allowsAutoTrust(isChangedKey: false,
                                             now: t0.addingTimeInterval(119)))
    }

    /// The invariant. A changed key is the man-in-the-middle signal and must be
    /// asked about however wide the window is.
    func testChangedKeyIsNeverAutoTrusted() {
        var policy = TrustBurstPolicy()
        policy.open(now: t0, duration: 3600)
        XCTAssertFalse(policy.allowsAutoTrust(isChangedKey: true, now: t0))
        XCTAssertFalse(policy.allowsAutoTrust(isChangedKey: true,
                                              now: t0.addingTimeInterval(1)))
    }

    func testWindowExpires() {
        var policy = TrustBurstPolicy()
        policy.open(now: t0, duration: 120)
        XCTAssertFalse(policy.allowsAutoTrust(isChangedKey: false,
                                              now: t0.addingTimeInterval(120)),
                       "the boundary is exclusive — expired means expired")
        XCTAssertFalse(policy.allowsAutoTrust(isChangedKey: false,
                                              now: t0.addingTimeInterval(300)))
    }

    func testCloseEndsItImmediately() {
        var policy = TrustBurstPolicy()
        policy.open(now: t0, duration: 120)
        policy.close()
        XCTAssertFalse(policy.allowsAutoTrust(isChangedKey: false, now: t0))
    }

    func testReopeningExtendsTheWindow() {
        var policy = TrustBurstPolicy()
        policy.open(now: t0, duration: 120)
        policy.open(now: t0.addingTimeInterval(100), duration: 120)
        XCTAssertTrue(policy.allowsAutoTrust(isChangedKey: false,
                                             now: t0.addingTimeInterval(200)))
    }
}

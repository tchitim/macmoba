import XCTest
@testable import MacMobaCore

final class TLSTrustTests: XCTestCase {

    /// The point of showing a fingerprint is that the user can compare it with
    /// one the server printed. `openssl x509 -fingerprint -sha256` and Keychain
    /// Access both use colon-separated uppercase hex, so we do too.
    func testFingerprintMatchesWhatOpenSSLPrints() {
        // SHA-256 of the empty input, the one digest with a published value
        // that needs no fixture file.
        let fingerprint = TLSFingerprint.sha256(der: Data())
        XCTAssertTrue(fingerprint.hasPrefix("E3:B0:C4:42:98:FC:1C:14"), fingerprint)
        XCTAssertEqual(fingerprint.split(separator: ":").count, 32)
        XCTAssertEqual(fingerprint.uppercased(), fingerprint)
    }

    func testFingerprintsAreStablePerCertificate() {
        let der = Data("a certificate".utf8)
        XCTAssertEqual(TLSFingerprint.sha256(der: der), TLSFingerprint.sha256(der: der))
        XCTAssertNotEqual(TLSFingerprint.sha256(der: der),
                          TLSFingerprint.sha256(der: Data("another".utf8)))
    }

    func testAnUnseenServerAsks() {
        XCTAssertEqual(WebCertificateTrust.outcome(stored: nil, offered: "AA:BB"),
                       .askFirstTime)
    }

    func testAPinnedCertificateGoesThroughSilently() {
        XCTAssertEqual(WebCertificateTrust.outcome(stored: "AA:BB", offered: "AA:BB"),
                       .trusted)
    }

    /// The case the whole mechanism exists for: never silently accepted.
    func testAChangedCertificateAsksAndShowsTheOldOne() {
        XCTAssertEqual(WebCertificateTrust.outcome(stored: "AA:BB", offered: "CC:DD"),
                       .askChanged(from: "AA:BB"))
    }

    /// Hex has no meaningful case. A store written in one case must not make an
    /// unchanged certificate raise the alarming "has changed" alert.
    func testCaseDoesNotCountAsAChange() {
        XCTAssertEqual(WebCertificateTrust.outcome(stored: "aa:bb", offered: "AA:BB"),
                       .trusted)
    }
}

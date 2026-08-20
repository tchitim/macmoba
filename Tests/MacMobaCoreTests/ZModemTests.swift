import XCTest
@testable import MacMobaCore

extension ZModemCoreTests {

    /// A send types `rz` on the remote to start the receiver. Typing it at an
    /// `rz` that is already running feeds the word into the transfer as data
    /// and wedges both ends, so a waiting receiver has to be recognised.
    func testAWaitingReceiverIsRecognised() {
        // What rz repeats while it waits: ZPAD ZPAD ZDLE 'B' "01…"
        let zrinit: [UInt8] = [0x2a, 0x2a, 0x18, 0x42, 0x30, 0x31, 0x30, 0x30]
        XCTAssertTrue(ZModem.receiverIsWaiting(in: zrinit))
    }

    /// A download announces itself with ZRQINIT — frame type 00, not 01 — and
    /// must not be mistaken for a receiver waiting to be fed.
    func testADownloadAnnouncementIsNotAWaitingReceiver() {
        let zrqinit: [UInt8] = [0x2a, 0x2a, 0x18, 0x42, 0x30, 0x30, 0x30, 0x30]
        XCTAssertFalse(ZModem.receiverIsWaiting(in: zrqinit))
        XCTAssertNotNil(ZModem.receiveTriggerIndex(in: zrqinit))
    }

    func testOrdinaryOutputIsNeither() {
        let text = Array("total 24\r\ndrwxr-xr-x 2 root root\r\n".utf8)
        XCTAssertFalse(ZModem.receiverIsWaiting(in: text))
        XCTAssertNil(ZModem.receiveTriggerIndex(in: text))
    }
}

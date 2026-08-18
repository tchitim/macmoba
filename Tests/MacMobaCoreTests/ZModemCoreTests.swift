import XCTest
@testable import MacMobaCore

final class ZModemCoreTests: XCTestCase {

    // MARK: - CRC

    func testCRC16OfZeroHeaderIsZero() {
        // A ZRQINIT header is five zero bytes; ZMODEM's CRC-16 of them is 0,
        // which is why the wire form is "**\x18B00000000000000".
        XCTAssertEqual(ZModem.crc16([0, 0, 0, 0, 0]), 0)
    }

    func testCRC16KnownVector() {
        // CRC-16/XMODEM of "123456789" is 0x31C3.
        XCTAssertEqual(ZModem.crc16(Array("123456789".utf8)), 0x31C3)
    }

    func testCRC32KnownVector() {
        // The canonical CRC-32 check value.
        XCTAssertEqual(ZModem.crc32(Array("123456789".utf8)), 0xCBF43926)
    }

    // MARK: - ZDLE escaping

    func testEscapeZDLEAndControls() {
        XCTAssertEqual(ZModem.escape([0x18]), [0x18, 0x58])          // ZDLE -> ZDLE ZDLEE
        XCTAssertEqual(ZModem.escape([0x11]), [0x18, 0x51])          // XON -> ZDLE (0x11^0x40)
        XCTAssertEqual(ZModem.escape([0x13]), [0x18, 0x53])          // XOFF
        XCTAssertEqual(ZModem.escape([0x91]), [0x18, 0xD1])          // 8-bit XON
    }

    func testEscapeLeavesOrdinaryBytes() {
        XCTAssertEqual(ZModem.escape(Array("hello".utf8)), Array("hello".utf8))
    }

    func testEscapeUnescapeRoundTrip() {
        let original: [UInt8] = [0x00, 0x18, 0x41, 0x11, 0x13, 0xFF, 0x90, 0x42]
        let escaped = ZModem.escape(original)
        // Walk the escaped stream back to plain bytes.
        var out: [UInt8] = []
        var i = 0
        while i < escaped.count {
            if escaped[i] == ZModem.ZDLE {
                out.append(ZModem.unescapeByte(escaped[i + 1])); i += 2
            } else {
                out.append(escaped[i]); i += 1
            }
        }
        XCTAssertEqual(out, original)
    }

    // MARK: - headers

    func testHexHeaderZRQINITWireForm() {
        let bytes = ZModem.hexHeader(.ZRQINIT)
        let expected: [UInt8] = [0x2A, 0x2A, 0x18, 0x42]            // * * ZDLE 'B'
            + Array("00000000000000".utf8)                          // type+4 and crc, all zero
            + [0x0D, 0x0A, 0x11]                                    // CR LF XON
        XCTAssertEqual(bytes, expected)
    }

    func testHexHeaderCarriesPosition() {
        // ZRPOS with position 1 → first payload byte 0x01, and a non-zero CRC.
        let (p0, p1, p2, p3) = ZModem.positionBytes(1)
        let bytes = ZModem.hexHeader(.ZRPOS, p0, p1, p2, p3)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x2A, 0x2A, 0x18, 0x42])
        // Frame type 9 = "09", position low byte "01".
        let hexPart = String(decoding: bytes[4..<14], as: UTF8.self)
        XCTAssertEqual(hexPart, "0901000000")
    }

    func testBinaryHeaderIntroAndEscaping() {
        let bytes = ZModem.binaryHeader(.ZDATA)
        XCTAssertEqual(Array(bytes.prefix(3)), [0x2A, 0x18, 0x41])  // * ZDLE 'A'
    }

    func testPositionBytesLittleEndian() {
        XCTAssertEqual(ZModem.positionBytes(0x04030201).0, 0x01)
        let (_, _, _, hi) = ZModem.positionBytes(0x04030201)
        XCTAssertEqual(hi, 0x04)
    }

    // MARK: - receive trigger detection

    func testDetectsZRQINITTrigger() {
        // What `sz` prints to announce itself: "rz\r" then the ZRQINIT header.
        let stream = Array("rz\r".utf8) + ZModem.hexHeader(.ZRQINIT)
        let idx = ZModem.receiveTriggerIndex(in: stream)
        XCTAssertNotNil(idx)
        // The index points at the leading '*' pads, so the receiver gets the
        // whole header.
        XCTAssertEqual(stream[idx!], ZModem.ZPAD)
        XCTAssertEqual(Array(stream[idx!..<idx! + 4]), [0x2A, 0x2A, 0x18, 0x42])
    }

    func testNoTriggerInOrdinaryOutput() {
        XCTAssertNil(ZModem.receiveTriggerIndex(in: Array("$ ls -la\r\n".utf8)))
    }
}

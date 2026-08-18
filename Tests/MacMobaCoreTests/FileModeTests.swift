import XCTest

@testable import MacMobaCore

final class FileModeTests: XCTestCase {
    // MARK: - parse

    func testParsesOctal() {
        XCTAssertEqual(FileMode.parse("755"), 0o755)
        XCTAssertEqual(FileMode.parse("0644"), 0o644)
        XCTAssertEqual(FileMode.parse("1777"), 0o1777)
        XCTAssertEqual(FileMode.parse(" 600 "), 0o600)
    }

    func testRejectsBadModes() {
        XCTAssertNil(FileMode.parse(""))
        XCTAssertNil(FileMode.parse("8"))       // 8 is not octal
        XCTAssertNil(FileMode.parse("rwx"))
        XCTAssertNil(FileMode.parse("75555"))   // too many digits
        XCTAssertNil(FileMode.parse("7a5"))
    }

    // MARK: - octalString (strips the file-type bits)

    func testOctalStringDropsTypeBits() {
        XCTAssertEqual(FileMode.octalString(0o040_755), "755")   // a directory
        XCTAssertEqual(FileMode.octalString(0o100_644), "644")   // a regular file
        XCTAssertEqual(FileMode.octalString(0o644), "644")
    }

    // MARK: - symbolic

    func testSymbolicBasics() {
        XCTAssertEqual(FileMode.symbolic(0o755), "rwxr-xr-x")
        XCTAssertEqual(FileMode.symbolic(0o644), "rw-r--r--")
        XCTAssertEqual(FileMode.symbolic(0o600), "rw-------")
        XCTAssertEqual(FileMode.symbolic(0o000), "---------")
        XCTAssertEqual(FileMode.symbolic(0o777), "rwxrwxrwx")
    }

    func testSymbolicIgnoresTypeBits() {
        XCTAssertEqual(FileMode.symbolic(0o100_644), "rw-r--r--")
    }

    /// setuid/setgid/sticky land in the execute column as ls shows them.
    func testSpecialBits() {
        XCTAssertEqual(FileMode.symbolic(0o4755), "rwsr-xr-x")   // setuid, x set → s
        XCTAssertEqual(FileMode.symbolic(0o4644), "rwSr--r--")   // setuid, no x → S
        XCTAssertEqual(FileMode.symbolic(0o2755), "rwxr-sr-x")   // setgid
        XCTAssertEqual(FileMode.symbolic(0o1777), "rwxrwxrwt")   // sticky, x set → t
        XCTAssertEqual(FileMode.symbolic(0o1666), "rw-rw-rwT")   // sticky, no x → T
    }

    func testRoundTripThroughParse() {
        for octal in ["755", "644", "600", "700", "444", "1777", "4755"] {
            let bits = FileMode.parse(octal)!
            XCTAssertEqual(FileMode.octalString(bits), octal.hasPrefix("0") ? String(octal.dropFirst()) : octal)
        }
    }
}

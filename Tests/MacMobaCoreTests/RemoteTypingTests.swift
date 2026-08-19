import XCTest
@testable import MacMobaCore

/// Typing is how the clipboard reaches a macOS remote desktop at all: its VNC
/// server ignores the standard clipboard message, and that message could only
/// have carried Latin-1 anyway.
final class RemoteTypingTests: XCTestCase {

    func testASCIIIsItsOwnKeysym() {
        XCTAssertEqual(RemoteTyping.keysyms(for: "abc"), [0x61, 0x62, 0x63])
        XCTAssertEqual(RemoteTyping.keysyms(for: "A1!"), [0x41, 0x31, 0x21])
        XCTAssertEqual(RemoteTyping.keysyms(for: " "), [0x20])
    }

    /// The whole reason this exists: 0x01000000 + code point is the Unicode
    /// keysym range. The bare code point — what the library does elsewhere —
    /// collides with the legacy keysym table and types something else.
    func testNonASCIIUsesTheUnicodeKeysymRange() {
        XCTAssertEqual(RemoteTyping.keysyms(for: "中"), [0x0100_4E2D])
        XCTAssertEqual(RemoteTyping.keysyms(for: "é"), [0x0100_00E9])
        XCTAssertEqual(RemoteTyping.keysyms(for: "—"), [0x0100_2014])
    }

    func testNewlinesAndTabsBecomeTheirKeys() {
        XCTAssertEqual(RemoteTyping.keysyms(for: "a\nb"), [0x61, 0xFF0D, 0x62])
        XCTAssertEqual(RemoteTyping.keysyms(for: "\r"), [0xFF0D])
        XCTAssertEqual(RemoteTyping.keysyms(for: "a\tb"), [0x61, 0xFF09, 0x62])
    }

    /// Invisible in the source, unpredictable at the far end.
    func testOtherControlCharactersAreDropped() {
        XCTAssertEqual(RemoteTyping.keysyms(for: "a\u{0}b\u{7}"), [0x61, 0x62])
        XCTAssertEqual(RemoteTyping.keysyms(for: "a\u{7f}"), [0x61])
    }

    func testEmptyTextTypesNothing() {
        XCTAssertTrue(RemoteTyping.keysyms(for: "").isEmpty)
    }

    /// An emoji is one scalar beyond the basic plane; it must not be split or
    /// truncated into a different character.
    func testAstralScalarsSurvive() {
        XCTAssertEqual(RemoteTyping.keysyms(for: "🐛"), [0x0101_F41B])
    }

    func testMixedTextKeepsItsOrder() {
        XCTAssertEqual(RemoteTyping.keysyms(for: "a中\nb"),
                       [0x61, 0x0100_4E2D, 0xFF0D, 0x62])
    }
}

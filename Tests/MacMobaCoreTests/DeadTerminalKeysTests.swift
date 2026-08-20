import XCTest
@testable import MacMobaCore

final class DeadTerminalKeysTests: XCTestCase {

    func testReturnReconnects() {
        XCTAssertEqual(DeadTerminalKey.action(for: [0x0d]), .reconnect)
        XCTAssertEqual(DeadTerminalKey.action(for: [0x0a]), .reconnect)
    }

    func testEscapeAloneCloses() {
        XCTAssertEqual(DeadTerminalKey.action(for: [0x1b]), .close)
    }

    /// The bug this exists to prevent: every arrow and function key begins with
    /// Escape, so testing for "contains 0x1b" would close the pane whenever
    /// someone pressed Up looking for their last command.
    func testEscapeSequencesAreNotEscape() {
        for sequence in [[0x1b, 0x5b, 0x41],          // Up
                         [0x1b, 0x5b, 0x42],          // Down
                         [0x1b, 0x4f, 0x50],          // F1
                         [0x1b, 0x5b, 0x33, 0x7e]] {  // Forward delete
            XCTAssertEqual(DeadTerminalKey.action(for: sequence.map(UInt8.init)), .ignore,
                           "\(sequence) must not be read as Escape")
        }
    }

    /// Typing into a dead session does nothing, including typing something that
    /// happens to end in a newline.
    func testOrdinaryTypingIsIgnored() {
        XCTAssertEqual(DeadTerminalKey.action(for: Array("ls".utf8)), .ignore)
        XCTAssertEqual(DeadTerminalKey.action(for: Array("ls\r".utf8)), .ignore)
        XCTAssertEqual(DeadTerminalKey.action(for: []), .ignore)
    }
}

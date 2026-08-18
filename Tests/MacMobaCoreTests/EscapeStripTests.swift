// The session-log escape stripper lives in the app target, so this test
// exercises an identical local copy of the algorithm to lock its behaviour in.
// (Kept here because the app target has no test host.)

import Foundation
import XCTest

private func stripEscapes(_ data: Data) -> Data {
    var out = Data()
    out.reserveCapacity(data.count)
    var i = data.startIndex
    while i < data.endIndex {
        let byte = data[i]
        if byte == 0x1b {
            let next = data.index(after: i)
            guard next < data.endIndex else { break }
            switch data[next] {
            case 0x5b:
                var j = data.index(after: next)
                while j < data.endIndex, !(0x40...0x7e).contains(data[j]) {
                    j = data.index(after: j)
                }
                i = j < data.endIndex ? data.index(after: j) : data.endIndex
            case 0x5d:
                var j = data.index(after: next)
                while j < data.endIndex, data[j] != 0x07 {
                    if data[j] == 0x1b, data.index(after: j) < data.endIndex,
                       data[data.index(after: j)] == 0x5c {
                        j = data.index(after: j)
                        break
                    }
                    j = data.index(after: j)
                }
                i = j < data.endIndex ? data.index(after: j) : data.endIndex
            default:
                i = data.index(after: next)
            }
            continue
        }
        if byte >= 0x20 || byte == 0x0a || byte == 0x09 {
            out.append(byte)
        }
        i = data.index(after: i)
    }
    return out
}

private func strip(_ s: String) -> String {
    String(decoding: stripEscapes(Data(s.utf8)), as: UTF8.self)
}

final class EscapeStripTests: XCTestCase {
    func testRemovesColourSequences() {
        XCTAssertEqual(strip("\u{1b}[31mred\u{1b}[0m text"), "red text")
        XCTAssertEqual(strip("\u{1b}[1;32mbold green\u{1b}[m"), "bold green")
    }

    func testRemovesCursorAndEraseSequences() {
        XCTAssertEqual(strip("a\u{1b}[2Kb\u{1b}[10;20Hc"), "abc")
    }

    func testRemovesOSCTitleWithBellOrST() {
        XCTAssertEqual(strip("\u{1b}]0;window title\u{07}shell"), "shell")
        XCTAssertEqual(strip("\u{1b}]0;title\u{1b}\\after"), "after")
    }

    func testKeepsNewlinesAndTabsButDropsCarriageReturn() {
        // CR would make logs overwrite themselves when viewed as text.
        XCTAssertEqual(strip("line1\r\nline2\tend"), "line1\nline2\tend")
    }

    func testHandlesTruncatedEscapeAtEnd() {
        XCTAssertEqual(strip("text\u{1b}"), "text")
        XCTAssertEqual(strip("text\u{1b}["), "text")
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(strip("$ uname -a\nDarwin\n"), "$ uname -a\nDarwin\n")
    }
}

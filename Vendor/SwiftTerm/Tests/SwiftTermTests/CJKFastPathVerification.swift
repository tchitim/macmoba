import XCTest
@testable import SwiftTerm

/// Proves the assumptions the CJK fast path is allowed to make, so that the
/// fast path is a measured equivalence and not a guess.
final class CJKFastPathVerification: XCTestCase {

    static let ranges: [ClosedRange<UInt32>] = [
        0x3000...0x3029,   // CJK symbols and punctuation, before the tone marks
        0x3030...0x303E,   // after U+302A-302F (combining), before U+303F (width 1)
        0x3041...0x3096,   // hiragana; U+3040/3097/3098 are unassigned, width 1
        0x309B...0x30FF,   // kana, resuming after the two combining sound marks
        0x3400...0x4DBF,   // CJK extension A
        0x4E00...0x9FFF,   // CJK unified ideographs
        0xAC00...0xD7A3,   // Hangul syllables
        0xF900...0xFAFF,   // CJK compatibility ideographs
        0xFF01...0xFF60,   // fullwidth forms
        0xFFE0...0xFFE6,   // fullwidth signs
    ]

    /// Every scalar in the ranges is two columns wide, so the fast path may
    /// return 2 instead of consulting the Unicode property tables.
    func testEveryScalarIsWidthTwo() {
        var checked = 0
        for range in Self.ranges {
            for v in range {
                guard let scalar = UnicodeScalar(v) else { continue }
                let w = UnicodeUtil.columnWidth(rune: scalar)
                XCTAssertEqual(w, 2, "U+\(String(v, radix: 16, uppercase: true)) is width \(w), not 2")
                checked += 1
            }
        }
        print("width: checked \(checked) scalars")
    }

    /// None of them can combine with a neighbour, so the fast path may skip
    /// the grapheme-cluster machinery entirely.
    func testNoScalarCanCombine() {
        var checked = 0
        for range in Self.ranges {
            for v in range {
                guard let scalar = UnicodeScalar(v) else { continue }
                let p = scalar.properties
                XCTAssertEqual(p.canonicalCombiningClass, .notReordered,
                               "U+\(String(v, radix: 16, uppercase: true)) has a combining class")
                XCTAssertFalse(p.isEmojiModifier, "U+\(String(v, radix: 16, uppercase: true)) is an emoji modifier")
                XCTAssertFalse(p.isVariationSelector, "U+\(String(v, radix: 16, uppercase: true)) is a variation selector")
                XCTAssertNotEqual(v, 0x200D)
                XCTAssertFalse(UnicodeUtil.isRegionalIndicator(scalar))
                checked += 1
            }
        }
        print("combining: checked \(checked) scalars")
    }

    /// And none of them joins the *previous* scalar into one grapheme cluster,
    /// which is the other way the general path would have combined them.
    func testDoesNotJoinPrecedingCharacter() {
        let bases: [Character] = ["a", "中", "あ", "한", "🙂", "e"]
        for range in Self.ranges {
            for v in stride(from: range.lowerBound, through: range.upperBound, by: 37) {
                guard let scalar = UnicodeScalar(v) else { continue }
                for base in bases {
                    let joined = String([base, Character(scalar)])
                    XCTAssertEqual(joined.count, 2,
                                   "U+\(String(v, radix: 16, uppercase: true)) merged with \(base)")
                }
            }
        }
    }
}

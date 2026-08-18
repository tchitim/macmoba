import XCTest
@testable import MacMobaCore

final class AttentionDetectorTests: XCTestCase {

    func testBareBellTriggers() {
        var d = AttentionDetector()
        XCTAssertEqual(d.observe(Array("build done\u{07}\n".utf8), at: 0), .bell)
    }

    /// Title changes end in BEL (OSC terminator) — they must not ring.
    func testOSCTitleTerminatorIsNotABell() {
        var d = AttentionDetector()
        let title = Array("\u{1B}]0;user@host: ~\u{07}".utf8)
        XCTAssertNil(d.observe(title, at: 0))
    }

    func testBellAfterOSCStillRings() {
        var d = AttentionDetector()
        let mixed = Array("\u{1B}]0;title\u{07}ready\u{07}".utf8)
        XCTAssertEqual(d.observe(mixed, at: 0), .bell)
    }

    func testOSCTerminatedByStringTerminator() {
        var d = AttentionDetector()
        // ESC ] ... ESC \  (ST) — then a real bell afterwards.
        let bytes = Array("\u{1B}]2;t\u{1B}\\\u{07}".utf8)
        XCTAssertEqual(d.observe(bytes, at: 0), .bell)
    }

    func testCSISequencesPassThrough() {
        var d = AttentionDetector()
        // Colour + cursor moves, then a bell: CSI must not swallow it.
        let bytes = Array("\u{1B}[1;31mred\u{1B}[0m\u{07}".utf8)
        XCTAssertEqual(d.observe(bytes, at: 0), .bell)
    }

    /// A string sequence split across two chunks keeps its state: the BEL that
    /// ends it in the second chunk is still a terminator, not a bell.
    func testOSCSpanningChunks() {
        var d = AttentionDetector()
        XCTAssertNil(d.observe(Array("\u{1B}]0;long tit".utf8), at: 0))
        XCTAssertNil(d.observe(Array("le here\u{07}".utf8), at: 1))
    }

    // MARK: - silence

    func testFirstOutputIsNotAResume() {
        var d = AttentionDetector(silenceThreshold: 30)
        XCTAssertNil(d.observe(Array("banner\n".utf8), at: 1000))
    }

    func testOutputAfterSilenceTriggers() {
        var d = AttentionDetector(silenceThreshold: 30)
        _ = d.observe(Array("$ make\n".utf8), at: 0)
        XCTAssertEqual(d.observe(Array("done\n".utf8), at: 45),
                       .resumedAfterSilence(45))
    }

    func testContinuousOutputDoesNotTrigger() {
        var d = AttentionDetector(silenceThreshold: 30)
        _ = d.observe(Array("a".utf8), at: 0)
        for t in 1...40 {
            XCTAssertNil(d.observe(Array("line\n".utf8), at: TimeInterval(t)),
                         "steady output at t=\(t) must not look like a resume")
        }
    }

    func testBellOutranksResume() {
        var d = AttentionDetector(silenceThreshold: 30)
        _ = d.observe(Array("x".utf8), at: 0)
        XCTAssertEqual(d.observe(Array("done\u{07}\n".utf8), at: 60), .bell)
    }

    func testResumeResetsTheClock() {
        var d = AttentionDetector(silenceThreshold: 30)
        _ = d.observe(Array("x".utf8), at: 0)
        XCTAssertNotNil(d.observe(Array("y".utf8), at: 40))   // resume fires
        XCTAssertNil(d.observe(Array("z".utf8), at: 45),
                     "5s after the resume is not another resume")
    }
}

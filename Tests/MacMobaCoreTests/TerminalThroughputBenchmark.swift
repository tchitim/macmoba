import XCTest
import MacMobaCore
#if canImport(AppKit)
import AppKit
import SwiftTerm
#endif

/// How fast the terminal actually is, so that "would libghostty be faster" can
/// be answered with numbers instead of adjectives.
///
/// Skipped unless MACMOBA_BENCH=1: it is a measurement, not an assertion about
/// correctness, and it costs seconds.
///
/// RUN IT IN RELEASE. `swift test -c release`, or the numbers are about ten
/// times too low and say more about the debug build than about the terminal.
///
/// Reference, M-series, 2026-09-02, after the CJK fast path in
/// Vendor/SwiftTerm (the CJK figure was 11.8 MB/s before it):
///
///     feed  plain      51 MB/s   = 53.6M chars/s
///     feed  coloured   27 MB/s
///     feed  CJK        32 MB/s   = 14.2M chars/s
///     draw  1200x800   3.5 ms/frame
///     draw  2560x1440  8.1 ms/frame
///     copy  10k lines  17 ms
///
/// Compare feed figures per CHARACTER, not per megabyte: a CJK character is
/// three bytes, so MB/s flatters it by roughly three times.
final class TerminalThroughputBenchmark: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["MACMOBA_BENCH"] == "1" }

    #if canImport(AppKit)
    /// Parsing and updating the terminal state — what happens to every byte a
    /// session delivers, whether or not anything is drawn.
    func testFeedThroughput() throws {
        try XCTSkipUnless(enabled, "set MACMOBA_BENCH=1 to measure")
        for (name, payload) in Self.payloads {
            let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
            let bytes = [UInt8](payload)
            let started = Date()
            view.feed(byteArray: bytes[...])
            let seconds = Date().timeIntervalSince(started)
            let mb = Double(bytes.count) / 1_048_576
            print(String(format: "feed  %-16@  %6.1f MB in %5.2fs  =  %6.1f MB/s",
                         name as NSString, mb, seconds, mb / seconds))
        }
    }

    /// The same bytes through the terminal core alone, with no view attached.
    ///
    /// This exists so the SwiftTerm figure can be compared honestly against
    /// libghostty-vt, which has no view to go through: measuring
    /// TerminalView.feed against ghostty_terminal_vt_write would be charging
    /// one side for dirty-range tracking the other never does.
    func testFeedThroughputCoreOnly() throws {
        try XCTSkipUnless(enabled, "set MACMOBA_BENCH=1 to measure")
        for (name, payload) in Self.payloads {
            let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
            let terminal = view.getTerminal()
            terminal.resize(cols: 120, rows: 40)
            let bytes = [UInt8](payload)
            let started = Date()
            terminal.feed(byteArray: bytes)
            let seconds = Date().timeIntervalSince(started)
            let mb = Double(bytes.count) / 1_048_576
            print(String(format: "core  %-16@  %6.1f MB in %5.2fs  =  %6.1f MB/s",
                         name as NSString, mb, seconds, mb / seconds))
        }
    }

    /// Drawing a screenful, which is the cost libghostty's GPU renderer would
    /// actually be replacing.
    ///
    /// ⚠️ This measures CoreGraphics, NOT the Metal renderer the app offers as
    /// an option. `cacheDisplay(in:to:)` draws into a bitmap rep, which forces
    /// the CG path; Metal needs a real layer and window to engage. So the app's
    /// GPU renderer is currently unmeasured, and any claim about how much it
    /// helps is unsupported until that gap is closed.
    func testDrawTime() throws {
        try XCTSkipUnless(enabled, "set MACMOBA_BENCH=1 to measure")
        for size in [CGSize(width: 1200, height: 800), CGSize(width: 2560, height: 1440)] {
            let view = TerminalView(frame: CGRect(origin: .zero, size: size))
            view.feed(byteArray: [UInt8](Self.colourful(lines: 200))[...])
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return XCTFail("no bitmap rep")
            }
            // One warm-up, then time a run of frames.
            view.cacheDisplay(in: view.bounds, to: rep)
            let frames = 60
            let started = Date()
            for _ in 0..<frames { view.cacheDisplay(in: view.bounds, to: rep) }
            let each = Date().timeIntervalSince(started) / Double(frames) * 1000
            print(String(format: "draw  %4.0f×%-4.0f      %6.2f ms/frame  (%3.0f fps ceiling)",
                         size.width, size.height, each, 1000 / each))
        }
    }

    /// Copying a large selection — the thing a user actually notices as a
    /// pause, and a completely different code path from parsing or drawing.
    func testCopySelection() throws {
        try XCTSkipUnless(enabled, "set MACMOBA_BENCH=1 to measure")
        for lines in [1_000, 10_000, 50_000] {
            let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
            view.getTerminal().resize(cols: 120, rows: 40)
            // The app keeps 10,000 lines. Without this the terminal holds
            // SwiftTerm's default 500, so every size below selected the same
            // 540 rows and the measurement said nothing about a big buffer.
            view.getTerminal().changeScrollback(TerminalDefaults.defaultScrollback)
            view.feed(byteArray: [UInt8](Self.plain(lines: lines))[...])
            view.selectAll()
            let started = Date()
            let text = view.getSelection() ?? ""
            let seconds = Date().timeIntervalSince(started)
            print(String(format: "copy  %6d lines  %8d chars in %6.3fs", lines, text.count, seconds))
        }
    }

    // Dragging a selection is not measured directly: the selection service is
    // internal to SwiftTerm, so a test in another module cannot drive it. Each
    // update redraws the view, so the cost per mouse move is the draw figure
    // above.

    // Reading the buffer back — what `read-screen` and session logging do — is
    // deliberately not measured here: scroll-invariant lines are not populated
    // without a real layout, so a headless run reports an empty buffer very
    // quickly, which is worse than no number at all.

    // MARK: - payloads

    private static var payloads: [(String, Data)] {
        [("plain", plain(lines: 200_000)),
         ("coloured", colourful(lines: 120_000)),
         ("CJK", cjk(lines: 120_000))]
    }

    private static func plain(lines: Int) -> Data {
        var text = ""
        for i in 0..<lines {
            text += "-rw-r--r--  1 root root  4096 Aug 21 09:00 file-\(i).log\r\n"
        }
        return Data(text.utf8)
    }

    /// What a build log or `ls --color` looks like: a colour change every few
    /// characters, which is where a parser earns its keep.
    private static func colourful(lines: Int) -> Data {
        var text = ""
        for i in 0..<lines {
            text += "\u{1b}[32mINFO\u{1b}[0m \u{1b}[1;34mmodule-\(i % 40)\u{1b}[0m "
                + "compiled \u{1b}[33m\(i)\u{1b}[0m objects in \u{1b}[36m1.2s\u{1b}[0m\r\n"
        }
        return Data(text.utf8)
    }

    private static func cjk(lines: Int) -> Data {
        var text = ""
        for i in 0..<lines {
            text += "第 \(i) 行：連線成功，正在同步遠端檔案與設定內容\r\n"
        }
        return Data(text.utf8)
    }
    #endif
}

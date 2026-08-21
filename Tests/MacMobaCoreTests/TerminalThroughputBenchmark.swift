import XCTest
#if canImport(AppKit)
import AppKit
import SwiftTerm
#endif

/// How fast the terminal actually is, so that "would libghostty be faster" can
/// be answered with numbers instead of adjectives.
///
/// Skipped unless MACMOBA_BENCH=1: it is a measurement, not an assertion about
/// correctness, and it costs seconds.
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

    /// Drawing a screenful, which is the cost libghostty's GPU renderer would
    /// actually be replacing.
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

// How much does the Metal renderer actually buy?
//
// The throughput benchmark cannot answer this: it draws with
// `cacheDisplay(in:to:)`, which renders into a bitmap and so always takes the
// CoreGraphics path. Metal needs a real layer in a real window.
//
// This counts FRAMES, not bytes. An earlier attempt timed how long a payload
// took to feed with the run loop pumping in between, and measured the parser
// instead — 6.4MB in 0.14s is 45 MB/s, which is parsing speed, not drawing.
//
// Counting frames needs a hook on each side:
//   - CoreGraphics: `displayIfNeeded()` draws synchronously, so one loop pass
//     is exactly one frame and counting passes is counting frames. (Its
//     `draw(_:)` is not open, so it cannot be overridden from here anyway.)
//   - Metal: the renderer is the MTKView's delegate, so a proxy delegate in
//     front of it counts real frames. Timing `draw()` calls would not work —
//     the renderer holds a frame semaphore and returns immediately when a
//     frame is in flight, and presents asynchronously besides.
//
// Vsync is disabled on the Metal layer, or every result would read 60fps
// regardless of how fast the renderer actually is.

import AppKit
import MetalKit
import SwiftTerm

/// Forwards to the real renderer, separating frames that drew from calls that
/// bailed out.
///
/// Counting every `draw(in:)` gives nonsense — 40,000 fps on first attempt —
/// because the renderer takes a frame semaphore and returns immediately when a
/// frame is already in flight. Those early returns are sub-microsecond while a
/// real frame is milliseconds, so duration separates them cleanly.
///
/// That semaphore is also what makes this a fair throughput measure rather
/// than a count of encode calls: a slot only frees when the GPU finishes the
/// previous frame, so the rate of successful acquisitions IS the rate of
/// completed frames, GPU pacing included.
final class CountingMTKDelegate: NSObject, MTKViewDelegate {
    let inner: MTKViewDelegate
    var drew = 0
    var bailed = 0
    private static let threshold = 0.00005   // 50µs
    init(_ inner: MTKViewDelegate) { self.inner = inner }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        inner.mtkView(view, drawableSizeWillChange: size)
    }
    func draw(in view: MTKView) {
        let t0 = Date()
        inner.draw(in: view)
        if Date().timeIntervalSince(t0) >= Self.threshold { drew += 1 } else { bailed += 1 }
    }
}

func busyScreen(rows: Int) -> [UInt8] {
    var s = ""
    for i in 0..<rows {
        s += "\u{1b}[3\(i % 8)m第 \(i) 行\u{1b}[0m INFO module-\(i % 40) "
           + "\u{1b}[1;34m連線成功\u{1b}[0m compiled \(i) objects in 1.2s\r\n"
    }
    return Array(s.utf8)
}

let seconds = 3.0

@MainActor
func measureCoreGraphics(size: CGSize) -> Double {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let view = TerminalView(frame: CGRect(origin: .zero, size: size))
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    view.feed(byteArray: busyScreen(rows: 400)[...])
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    var frames = 0
    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
        view.setNeedsDisplay(view.bounds)
        view.displayIfNeeded()
        frames += 1
    }
    let elapsed = Date().timeIntervalSince(started)
    window.orderOut(nil)
    return elapsed / Double(frames) * 1000
}

@MainActor
func measureMetal(size: CGSize) -> Double? {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let view = TerminalView(frame: CGRect(origin: .zero, size: size))
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    do { try view.setUseMetal(true) } catch { window.orderOut(nil); return nil }

    guard let mtk = view.subviews.compactMap({ $0 as? MTKView }).first,
          let real = mtk.delegate else { window.orderOut(nil); return nil }
    // Without this every number would come back at the refresh rate, which
    // measures the display and not the renderer.
    (mtk.layer as? CAMetalLayer)?.displaySyncEnabled = false
    let counter = CountingMTKDelegate(real)
    mtk.delegate = counter

    view.feed(byteArray: busyScreen(rows: 400)[...])
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))

    counter.drew = 0; counter.bailed = 0
    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
        mtk.setNeedsDisplay(mtk.bounds)
        // The renderer bails while a frame is in flight, so the loop has to
        // let the completion handler run rather than spinning on draw().
        _ = RunLoop.current.run(mode: .default, before: Date())
    }
    let elapsed = Date().timeIntervalSince(started)
    let frames = counter.drew
    print(String(format: "    (metal: %d frames drew, %d calls bailed on the semaphore)",
                 counter.drew, counter.bailed))
    mtk.delegate = real
    window.orderOut(nil)
    guard frames > 0 else { return nil }
    return elapsed / Double(frames) * 1000
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    print("full-screen redraws of a busy screenful, \(Int(seconds))s per measurement\n")
    for size in [CGSize(width: 1200, height: 800), CGSize(width: 2560, height: 1440)] {
        let cg = measureCoreGraphics(size: size)
        let mt = measureMetal(size: size)
        let mtText = mt.map { String(format: "%6.2f ms (%3.0f fps)", $0, 1000/$0) } ?? "   unavailable"
        let ratio = mt.map { String(format: "%5.2fx", cg / $0) } ?? "    -"
        print(String(format: "%4.0f×%-5.0f  CoreGraphics %6.2f ms (%3.0f fps)   Metal %@   -> %@",
                     size.width, size.height, cg, 1000/cg, mtText as NSString, ratio as NSString))
    }
}

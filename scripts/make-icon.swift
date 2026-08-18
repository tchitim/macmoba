// Generates AppIcon.icns: dark rounded-square with a green terminal prompt.
// Run: swift scripts/make-icon.swift   (writes AppIcon.icns in repo root)

import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // macOS icon grid: content square is ~80% of canvas, radius ~22.5%
    let inset = size * 0.10
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.225
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.25, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1)
    )!
    gradient.draw(in: shape, angle: -90)

    // subtle top edge highlight
    NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
    shape.lineWidth = max(1, size / 256)
    shape.stroke()

    // "❯_" prompt in green monospace
    let promptSize = rect.width * 0.42
    let font = NSFont.monospacedSystemFont(ofSize: promptSize, weight: .bold)
    let green = NSColor(calibratedRed: 0.30, green: 0.87, blue: 0.50, alpha: 1)

    let chevron = NSAttributedString(string: "❯", attributes: [
        .font: font, .foregroundColor: green,
    ])
    let cSize = chevron.size()
    chevron.draw(at: NSPoint(
        x: rect.minX + rect.width * 0.16,
        y: rect.midY - cSize.height / 2
    ))

    let underscore = NSAttributedString(string: "_", attributes: [
        .font: font, .foregroundColor: green.withAlphaComponent(0.9),
    ])
    let uSize = underscore.size()
    underscore.draw(at: NSPoint(
        x: rect.minX + rect.width * 0.50,
        y: rect.midY - uSize.height / 2
    ))

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    let img = drawIcon(size: CGFloat(base))
    writePNG(img, pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    let img2 = drawIcon(size: CGFloat(base * 2))
    writePNG(img2, pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")

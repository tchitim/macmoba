// Turning a pane size into a desktop size to ask an RDP server for.
//
// Extracted from the view layer because this is where the fiddly parts live —
// the points-to-pixels conversion and the width rounding — and because a Retina
// result cannot be observed on a 1x development display.

import Foundation

public enum RDPDesktopSize {
    /// Minimum desktop worth asking for. A pane can legitimately be smaller
    /// (or, at connect time, not laid out yet and therefore zero); the desktop
    /// is letterboxed into it rather than the server being asked for something
    /// it will refuse.
    public static let minimumWidth = 640
    public static let minimumHeight = 480

    /// Caps a fixed desktop size to what the display can actually show.
    ///
    /// A size typed into the editor is not checked against anything, so it can
    /// easily exceed the screen — at which point the desktop is scaled down to
    /// fit and the extra pixels do nothing but make the text smaller.
    public static func capped(_ size: (width: Int, height: Int),
                              toScreenPixels screenPixels: CGSize?) -> (width: Int, height: Int) {
        guard let screenPixels, screenPixels.width >= 1, screenPixels.height >= 1 else {
            return size
        }
        let width = max(minimumWidth, min(size.width, Int(screenPixels.width.rounded()))) & ~3
        let height = max(minimumHeight, min(size.height, Int(screenPixels.height.rounded())))
        return (width, height)
    }

    /// Desktop size in **pixels** for a pane measured in points.
    ///
    /// `scale` is the display's backing scale factor. Asking in points on a
    /// Retina screen yields a half-resolution desktop that then has to be
    /// upscaled, which is exactly the soft-text problem this avoids.
    ///
    /// Width is rounded **down** to a multiple of 4: RDP servers reject widths
    /// that are not, and rounding down keeps the desktop inside the pane.
    /// Rounding up would make the server send a desktop slightly wider than
    /// there is room for.
    ///
    /// - Parameter enforceMinimum: applied when connecting, where too small a
    ///   request is refused outright. Resizes pass `false` so that following the
    ///   pane stays exact.
    /// - Parameter screenPixels: the resolution of the display the session is
    ///   shown on. The desktop is capped to it, because asking a server for
    ///   more pixels than can ever be displayed only costs bandwidth and
    ///   shrinks everything: the extra detail is thrown away when the picture
    ///   is scaled down to fit. Pass nil to leave the size uncapped, which is
    ///   what a session spanning several displays needs — exceeding any single
    ///   screen is the whole point there.
    public static func pixels(forPoints points: CGSize, scale: CGFloat,
                              enforceMinimum: Bool,
                              screenPixels: CGSize? = nil) -> (width: Int, height: Int) {
        let safeScale = scale > 0 ? scale : 1
        var width = Int((points.width * safeScale).rounded())
        var height = Int((points.height * safeScale).rounded())

        if let screenPixels, screenPixels.width >= 1, screenPixels.height >= 1 {
            width = min(width, Int(screenPixels.width.rounded()))
            height = min(height, Int(screenPixels.height.rounded()))
        }

        if enforceMinimum {
            width = max(minimumWidth, width)
            height = max(minimumHeight, height)
        }
        width = max(0, width) & ~3
        height = max(0, height)
        return (width, height)
    }
}

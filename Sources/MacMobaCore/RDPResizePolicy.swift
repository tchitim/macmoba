// When a session is allowed to renegotiate its desktop size, and what to show
// when the desktop turns out not to match the monitor layout.
//
// Both decisions live here rather than in the view because getting either one
// wrong produces a black screen, and a black screen is exactly what cannot be
// reproduced on a one-display development machine.

import Foundation

public enum RDPResizePolicy {
    /// Whether the session may ask the server to change the desktop size
    /// through the display-control channel.
    ///
    /// A session spanning displays must NOT, even though it follows the window
    /// in every other respect. The display-control request carries a single
    /// rectangle, so sending one collapses a multi-monitor desktop down to one
    /// pane's worth of pixels — after which every monitor at a non-zero offset
    /// lies outside the framebuffer and its screen goes black. The desktop of a
    /// spanning session is pinned to the monitor layout; the pane letterboxes
    /// its slice instead.
    public static func allowsDynamicResize(spansDisplays: Bool, fitsWindow: Bool) -> Bool {
        fitsWindow && !spansDisplays
    }

    /// The part of the framebuffer a view should actually put on screen.
    ///
    /// - Returns: the clipped slice, or nil meaning "the whole framebuffer".
    ///
    /// A slice that falls entirely outside the framebuffer means the desktop
    /// and the monitor layout have disagreed — the size changed underneath us,
    /// or a screen was unplugged. Showing the whole desktop scaled down is
    /// wrong, but it is visibly wrong; returning nothing paints black, which
    /// looks identical to a session that has died.
    public static func visibleSlice(_ slice: CGRect?, in desktop: CGSize) -> CGRect? {
        guard let slice, desktop.width >= 1, desktop.height >= 1 else { return nil }
        let bounded = slice.intersection(
            CGRect(x: 0, y: 0, width: desktop.width, height: desktop.height))
        guard bounded.width >= 1, bounded.height >= 1 else { return nil }
        return bounded
    }
}

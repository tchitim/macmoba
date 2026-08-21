// Where a live remote surface lives while SwiftUI rearranges around it.
//
// A VNC framebuffer, an RDP surface and a WKWebView are each one long-lived
// AppKit view owned by its session, not by the view tree. SwiftUI hands them to
// whichever `NSViewRepresentable` is currently showing that pane — and during a
// rearrangement two representables exist at once: the new pane's, and the old
// one's, which still gets an update pass on its way out.
//
// Whoever calls last wins, so the loser can be the one on screen. That is how a
// remote desktop ended up with a superview, its correct size, a live connection
// delivering frames — and no window to draw in.

import AppKit

/// The plain view SwiftUI owns, which tells us the moment it joins a window.
///
/// Needed because the safe rule below refuses to move a live surface into a
/// host that is not on screen yet — so something has to ask again once it is,
/// and SwiftUI's own update pass is not guaranteed to come at that moment.
final class SurfaceHostView: NSView {
    var onWindowChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

enum SurfaceHosting {
    /// Move `surface` into `host`, unless that would take it off screen.
    ///
    /// A host with no window is either about to get one or about to be thrown
    /// away, and those look identical from here. Refusing the move costs
    /// nothing in the first case — the next update pass runs once the host is
    /// installed — and saves the session in the second.
    static func attach(_ surface: NSView, to host: NSView) {
        guard surface.superview !== host else { return }
        if host.window == nil && surface.window != nil { return }
        surface.removeFromSuperview()
        surface.frame = host.bounds
        surface.autoresizingMask = [.width, .height]
        host.addSubview(surface)
    }
}

// Describing this Mac's displays to an RDP server.
//
// The two coordinate systems disagree in exactly the way that produces a
// plausible-looking but wrong layout:
//
//   macOS  origin at the primary screen's BOTTOM-left, y increases upward
//   RDP    origin at the primary monitor's TOP-left,    y increases downward
//
// So a screen physically above the primary has a positive y on macOS and a
// negative y in RDP. Getting the sign wrong still produces a valid-looking
// layout that a server will accept — the windows just end up on the wrong
// screen — which is why this is separated from any AppKit call and tested
// directly.

import CoreGraphics
import Foundation

public struct RDPMonitor: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
    public var width: Int32
    public var height: Int32
    public var isPrimary: Bool
    /// Percentage, as RDP's desktopScaleFactor expects: 100 for a 1x display,
    /// 200 for a Retina one.
    public var scalePercent: UInt32
    /// Which entry of the screen list this came from.
    ///
    /// Needed because the returned array is SORTED (primary first), so its
    /// order no longer matches `NSScreen.screens`. Pairing by position put a
    /// screen's picture on the wrong display.
    public var screenIndex: Int
    /// The display this came from, as CoreGraphics identifies it.
    ///
    /// `screenIndex` alone is not enough: unplugging a display renumbers
    /// `NSScreen.screens`, so an index captured when the session connected can
    /// afterwards point at a different physical screen. Zero means unknown, in
    /// which case the index is all there is.
    public var displayID: UInt32

    public init(x: Int32, y: Int32, width: Int32, height: Int32,
                isPrimary: Bool, scalePercent: UInt32 = 100,
                screenIndex: Int = 0, displayID: UInt32 = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isPrimary = isPrimary
        self.scalePercent = scalePercent
        self.screenIndex = screenIndex
        self.displayID = displayID
    }
}

public enum RDPMonitorLayout {
    /// A display as AppKit describes it, so this file needs no AppKit import.
    public struct Screen: Equatable, Sendable {
        /// In macOS global coordinates: origin bottom-left, y up.
        public var frame: CGRect
        public var scale: CGFloat
        public var isPrimary: Bool
        /// `NSScreenNumber` from the screen's device description. Zero when the
        /// caller has none to give.
        public var displayID: UInt32

        public init(frame: CGRect, scale: CGFloat, isPrimary: Bool,
                    displayID: UInt32 = 0) {
            self.frame = frame
            self.scale = scale
            self.isPrimary = isPrimary
            self.displayID = displayID
        }
    }

    /// RDP allows at most 16 monitors.
    public static let maximumMonitors = 16

    /// Converts screens into monitor definitions, in pixels, with the primary
    /// at the origin.
    ///
    /// Returns an empty array when there is no primary screen — a layout with
    /// no primary is rejected by the server, and sending one is worse than
    /// falling back to a single-monitor session.
    public static func monitors(for screens: [Screen]) -> [RDPMonitor] {
        guard let primary = screens.first(where: \.isPrimary) else { return [] }
        let usable = Array(screens.prefix(maximumMonitors))

        // Every screen's SIZE is its own pixel count. That part is unambiguous.
        let sizes = usable.map { screen -> (width: Int32, height: Int32, scale: CGFloat) in
            let scale = screen.scale > 0 ? screen.scale : 1
            return (Int32((screen.frame.width * scale).rounded()) & ~1,
                    Int32((screen.frame.height * scale).rounded()) & ~1,
                    scale)
        }

        // Positions are the hard part. macOS arranges screens in POINTS; RDP
        // wants a PIXEL grid that tiles with no gaps and no overlaps. When the
        // displays share a scale factor those two agree, so the real geometry
        // can be used. When they do not — a 2x laptop screen beside a 1x
        // external — there is no scale that maps the point layout onto a
        // gap-free pixel layout, and a naive conversion produces a monitor
        // floating thousands of pixels away. FreeRDP rejects that outright
        // ("Monitor configuration has gaps"), so the connection fails.
        let uniformScale = Set(sizes.map(\.scale)).count == 1
        let placed: [RDPMonitor]
        if uniformScale, let scale = sizes.first?.scale {
            placed = zip(usable, sizes).enumerated().map { index, pair in
                let (screen, size) = pair
                return RDPMonitor(
                    x: Int32(((screen.frame.minX - primary.frame.minX) * scale).rounded()),
                    y: Int32(((primary.frame.maxY - screen.frame.maxY) * scale).rounded()),
                    width: size.width, height: size.height,
                    isPrimary: screen.isPrimary,
                    scalePercent: UInt32((scale * 100).rounded()),
                    screenIndex: index, displayID: screen.displayID)
            }
            // Even with one scale, a genuinely detached arrangement has gaps.
            if hasGaps(placed) { return tiled(usable, sizes: sizes, primary: primary) }
        } else {
            placed = tiled(usable, sizes: sizes, primary: primary)
        }

        let sorted = placed.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }
        // Never hand back something the server will refuse: an empty layout
        // means "connect as a single monitor", which works, while an invalid
        // one means the session does not connect at all.
        return isUsable(sorted) ? sorted : []
    }

    /// Rebuilds the layout so monitors are exactly adjacent, keeping which side
    /// of the primary each screen is on. The spatial arrangement is
    /// approximated — screens are snapped flush against the primary rather than
    /// keeping their exact offsets — because an approximate layout connects and
    /// an exact one does not.
    private static func tiled(_ screens: [Screen],
                              sizes: [(width: Int32, height: Int32, scale: CGFloat)],
                              primary: Screen) -> [RDPMonitor] {
        guard let primaryIndex = screens.firstIndex(where: \.isPrimary) else { return [] }
        let primarySize = sizes[primaryIndex]

        var monitors: [RDPMonitor] = []
        // Running edges, so several screens on the same side stack rather than
        // landing on top of each other.
        var rightEdge = primarySize.width
        var leftEdge: Int32 = 0
        var bottomEdge = primarySize.height
        var topEdge: Int32 = 0

        for (index, screen) in screens.enumerated() {
            let size = sizes[index]
            if screen.isPrimary {
                monitors.append(RDPMonitor(x: 0, y: 0, width: size.width, height: size.height,
                                           isPrimary: true,
                                           scalePercent: UInt32((size.scale * 100).rounded()),
                                           screenIndex: index, displayID: screen.displayID))
                continue
            }
            // Which side is it on? Compare centres in point space, and use the
            // larger separation so a screen that is both below and to the right
            // goes where it mostly is.
            let dx = screen.frame.midX - primary.frame.midX
            let dy = screen.frame.midY - primary.frame.midY
            let x: Int32
            let y: Int32
            if abs(dx) >= abs(dy) {
                if dx >= 0 { x = rightEdge; rightEdge += size.width }
                else { leftEdge -= size.width; x = leftEdge }
                y = 0
            } else {
                // macOS y grows upward, RDP downward.
                if dy <= 0 { y = bottomEdge; bottomEdge += size.height }
                else { topEdge -= size.height; y = topEdge }
                x = 0
            }
            monitors.append(RDPMonitor(x: x, y: y, width: size.width, height: size.height,
                                       isPrimary: false,
                                       scalePercent: UInt32((size.scale * 100).rounded()),
                                       screenIndex: index, displayID: screen.displayID))
        }
        return monitors
    }

    /// The monitor belonging to a particular display.
    ///
    /// Identity first, position second. A session that connected with two
    /// screens and is now down to one has a stale `screenIndex` for every
    /// monitor, and matching on it alone hands a screen the *other* display's
    /// part of the desktop — which is how a window on the built-in screen ended
    /// up showing the external monitor's picture.
    ///
    /// Returns nil rather than guessing when nothing matches: the caller knows
    /// whether the whole desktop or nothing at all is the better fallback.
    public static func monitor(in monitors: [RDPMonitor],
                               displayID: UInt32, screenIndex: Int) -> RDPMonitor? {
        if displayID != 0, let byID = monitors.first(where: { $0.displayID == displayID }) {
            return byID
        }
        // Only trust the index when the layout predates display IDs entirely;
        // otherwise a known-but-absent ID means this screen is not part of the
        // session, and the index would point at somebody else's monitor.
        if monitors.allSatisfy({ $0.displayID == 0 }) {
            return monitors.first { $0.screenIndex == screenIndex }
        }
        return nil
    }

    /// Where a monitor's picture actually sits in the framebuffer.
    ///
    /// RDP puts the PRIMARY monitor at (0,0), so a screen above or to the left
    /// of it has negative coordinates — but the framebuffer starts at the
    /// top-left of the whole bounding box, with nothing negative in it. A
    /// laptop with an external screen standing above it is the everyday case:
    /// used raw, the external's slice is at y = -2160 and crops to nothing
    /// (a black screen), while the laptop's own slice lands on the external's
    /// pixels instead of its own.
    public static func framebufferRect(of monitor: RDPMonitor,
                                       in monitors: [RDPMonitor]) -> CGRect {
        let minX = monitors.map(\.x).min() ?? 0
        let minY = monitors.map(\.y).min() ?? 0
        return CGRect(x: CGFloat(monitor.x - minX), y: CGFloat(monitor.y - minY),
                      width: CGFloat(monitor.width), height: CGFloat(monitor.height))
    }

    /// Splits a layout into "the screen the window is on" and "the screens that
    /// need a window of their own".
    ///
    /// Together these must cover every screen exactly once. Getting it wrong by
    /// assuming the window is on the primary screen covered the session's own
    /// display with a second window and left another display with nothing.
    public static func split(_ monitors: [RDPMonitor], hostScreenIndex: Int)
        -> (host: RDPMonitor?, others: [RDPMonitor]) {
        let host = monitors.first { $0.screenIndex == hostScreenIndex }
            ?? monitors.first(where: \.isPrimary)
        let hostIndex = host?.screenIndex
        return (host, monitors.filter { $0.screenIndex != hostIndex })
    }

    /// True when any monitor fails to share an edge with another. FreeRDP
    /// refuses such a layout during pre-connect, so it has to be caught here.
    static func hasGaps(_ monitors: [RDPMonitor]) -> Bool {
        guard monitors.count > 1 else { return false }
        for monitor in monitors {
            let touches = monitors.contains { other in
                guard other != monitor else { return false }
                let sharesVerticalEdge =
                    (other.x == monitor.x + monitor.width || monitor.x == other.x + other.width)
                    && other.y < monitor.y + monitor.height && monitor.y < other.y + other.height
                let sharesHorizontalEdge =
                    (other.y == monitor.y + monitor.height || monitor.y == other.y + other.height)
                    && other.x < monitor.x + monitor.width && monitor.x < other.x + other.width
                return sharesVerticalEdge || sharesHorizontalEdge
            }
            if !touches { return true }
        }
        return false
    }

    /// The desktop size to ask for: the bounding box of every monitor.
    ///
    /// Not the sum of the widths — monitors can be stacked, or offset — and not
    /// just the primary's size, which is what makes a multi-monitor session
    /// render into the top-left corner only.
    public static func boundingSize(of monitors: [RDPMonitor]) -> (width: Int, height: Int) {
        guard !monitors.isEmpty else { return (0, 0) }
        let minX = monitors.map(\.x).min() ?? 0
        let minY = monitors.map(\.y).min() ?? 0
        let maxX = monitors.map { $0.x + $0.width }.max() ?? 0
        let maxY = monitors.map { $0.y + $0.height }.max() ?? 0
        return (Int(maxX - minX), Int(maxY - minY))
    }

    /// Whether a layout is one a server will accept. Checked before sending,
    /// because an invalid layout is refused during capability exchange and
    /// surfaces as a bare connection failure with no explanation.
    public static func isUsable(_ monitors: [RDPMonitor]) -> Bool {
        guard !monitors.isEmpty, monitors.count <= maximumMonitors else { return false }
        guard monitors.filter(\.isPrimary).count == 1 else { return false }
        guard let primary = monitors.first(where: \.isPrimary),
              primary.x == 0, primary.y == 0 else { return false }
        guard monitors.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return false }
        // A gap makes FreeRDP refuse the whole connection during pre-connect,
        // so it is not merely untidy.
        guard !hasGaps(monitors) else { return false }
        // Overlapping monitors are not a layout any real arrangement produces,
        // and servers behave unpredictably when given them.
        for (index, monitor) in monitors.enumerated() {
            for other in monitors[(index + 1)...] where overlaps(monitor, other) {
                return false
            }
        }
        return true
    }

    private static func overlaps(_ a: RDPMonitor, _ b: RDPMonitor) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width
            && a.y < b.y + b.height && b.y < a.y + a.height
    }
}

// Capturing input for a remote desktop, and letting go of it again.
//
// While a remote desktop holds the keyboard, the keys that would normally
// belong to this Mac — ⌘Tab, Spotlight, the input-source switch — go to the
// remote instead, which is the whole point: you are working over there. That
// makes the release gesture safety equipment, so it has to be something you
// cannot press by accident and cannot fail to press when you need it.
//
// Escape twice was tried first and withdrawn. Escape has to keep working on
// the remote — vim, cancelling a composition, leaving full screen — so both
// presses were forwarded, and any remote that reads Escape twice as its own
// shortcut fired along with the release. Claude Code, running on the remote,
// does exactly that.

import CoreGraphics
import Foundation

/// Where the remote pointer is, driven by hardware deltas rather than by the
/// local cursor's position — the pointer is decoupled from the display while
/// input is captured, so its screen position stops meaning anything and only
/// the movement it reports still does.
///
/// The position is kept in framebuffer pixels as a fraction, because a scaled
/// desktop turns one point of hand movement into a fraction of a pixel;
/// rounding on every event would drop slow movement entirely.
public struct RelativePointer: Equatable {
    public private(set) var position: CGPoint
    /// The remote screen, in its own pixels.
    public let size: CGSize

    public init(position: CGPoint, size: CGSize) {
        self.size = size
        self.position = .zero
        self.position = Self.clamped(position, in: size)
    }

    /// Apply one mouse-moved event. `scale` is how many view points the remote
    /// draws each pixel at, so dividing by it converts hand movement into
    /// remote pixels.
    ///
    /// A single event that would cross half the remote screen is discarded. No
    /// hand produces that between two mouse reports; what does produce it is
    /// the cursor being repositioned underneath us, and letting one through
    /// throws the pointer to the far side of the screen.
    public mutating func move(dx: CGFloat, dy: CGFloat, scale: CGFloat) {
        let scale = scale > 0 ? scale : 1
        let step = CGPoint(x: dx / scale, y: dy / scale)
        guard abs(step.x) < size.width / 2, abs(step.y) < size.height / 2 else { return }
        position = Self.clamped(CGPoint(x: position.x + step.x,
                                        y: position.y + step.y), in: size)
    }

    /// What to put in a VNC pointer event.
    public var framebufferPoint: (x: UInt16, y: UInt16) {
        (UInt16(position.x.rounded(.down)), UInt16(position.y.rounded(.down)))
    }

    private static func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), max(size.width - 1, 0)),
                y: min(max(point.y, 0), max(size.height - 1, 0)))
    }
}

/// Recognises "press ⌃⌥ and let go" — the release gesture that cannot collide
/// with anything on the remote, because holding two modifiers and pressing
/// nothing means nothing to any program. Escape twice does collide: Claude Code
/// reads it as "go back a message", and the release forwards both presses on
/// purpose so that Escape keeps working over there.
public struct ModifierChordRelease {
    private var armed = false

    public init() {}

    /// Feed every modifier change. `held` is true while exactly Control and
    /// Option are down. Returns true when they are let go having been held
    /// alone — the gesture completes on release, so it needs no timer and
    /// cannot fire while you are still deciding.
    public mutating func modifiersChanged(held: Bool) -> Bool {
        if held {
            armed = true
            return false
        }
        defer { armed = false }
        return armed
    }

    /// Any other key cancels it: ⌃⌥ plus a letter is a shortcut the remote
    /// should get, not a half-finished release.
    public mutating func otherKeyPressed() {
        armed = false
    }

    public mutating func reset() {
        armed = false
    }
}

public enum PointerClamp {
    /// The nearest point inside `rect`. Used to keep the pointer from leaving a
    /// captured remote desktop: `maxX`/`maxY` are outside the rectangle, so the
    /// clamped point stops one unit short of them.
    public static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return point }
        return CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1),
                       y: min(max(point.y, rect.minY), rect.maxY - 1))
    }
}

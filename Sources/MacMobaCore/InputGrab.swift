// Capturing input for a remote desktop, and letting go of it again.
//
// While a remote desktop holds the keyboard, the keys that would normally
// belong to this Mac — ⌘Tab, Spotlight, the input-source switch — go to the
// remote instead, which is the whole point: you are working over there. That
// makes the release gesture safety equipment, so it has to be something you
// cannot press by accident and cannot fail to press when you need it.
//
// Escape twice is what was chosen. The subtlety is that Escape still has to
// work on the remote (vim, cancelling a composition, leaving full screen), so
// every press is forwarded as it happens and the second one merely also
// releases the grab. The remote therefore sees two Escapes when you let go,
// which is harmless, and never loses a single one — the alternative, holding
// the first Escape back to see whether a second arrives, would put a delay on
// every Escape you type.

import CoreGraphics
import Foundation

/// Recognises the double-Escape release gesture.
public struct DoubleEscapeRelease {
    /// How close together the two presses must be.
    public let window: TimeInterval
    private var previousPress: TimeInterval?

    public init(window: TimeInterval = 0.5) {
        self.window = window
    }

    /// Feed every Escape press, with a monotonic timestamp (`NSEvent.timestamp`).
    /// Returns true when this press completes the gesture.
    ///
    /// Completing it clears the state, so a run of Escapes releases once rather
    /// than on every press after the first.
    public mutating func escapePressed(at time: TimeInterval) -> Bool {
        if let previousPress, time - previousPress <= window {
            self.previousPress = nil
            return true
        }
        previousPress = time
        return false
    }

    /// Forget any half-finished gesture — on grab, on release, on losing focus.
    public mutating func reset() {
        previousPress = nil
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

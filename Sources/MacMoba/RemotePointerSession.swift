// The pointer while a remote desktop holds it: decoupled from this Mac's
// display and driven by raw movement, the way a virtual machine does it.
//
// Pinning the cursor at the window edge (what capture did first) stops it
// escaping, but the remote pointer still stops dead at the edge of the window
// rather than carrying on across the remote screen. Decoupling fixes that:
// `CGAssociateMouseAndMouseCursorPosition(false)` leaves the local cursor
// parked while the mouse keeps reporting movement, and that movement drives a
// pointer that lives in the REMOTE screen's coordinates.
//
// The cursor you see over a VNC session is the local NSCursor: RoyalVNC
// hard-codes the cursor pseudo-encoding, so the server draws no pointer into
// the framebuffer and rendering it is the client's job. Rather than hide it and
// draw a copy — which showed the wrong shape, an I-beam on the remote's own
// desktop — the real cursor is left visible and warped to the tracked
// position. Warping does not produce hardware movement, so it cannot feed back
// into the deltas, and what is drawn is exactly what an uncaptured session
// draws, because it is the same cursor.

import AppKit
import MacMobaCore
import RoyalVNCKit

@MainActor
final class RemotePointerSession {
    private weak var view: VNCCAFramebufferView?
    private var pointer: RelativePointer
    private var restoreMouseMoved: Bool?

    /// - Parameter viewPoint: where the grabbing click landed, in the
    ///   framebuffer view's own (bottom-left origin) coordinates.
    init?(view: VNCCAFramebufferView, startingAt viewPoint: CGPoint) {
        let size = view.framebufferSize
        guard size.width > 1, size.height > 1 else { return nil }
        self.view = view
        self.pointer = RelativePointer(position: Self.framebufferPoint(of: viewPoint, in: view),
                                       size: size)

        if let window = view.window {
            // Tracking areas stop producing moves once the cursor is parked;
            // the window has to post them itself or the pointer freezes.
            restoreMouseMoved = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
        }
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    // MARK: - input

    func move(dx: CGFloat, dy: CGFloat) {
        guard let view else { return }
        // AppKit's deltaY grows downwards, which is also how the framebuffer
        // counts rows, so it passes through unflipped.
        pointer.move(dx: dx, dy: dy, scale: view.scaleRatio)
        let point = pointer.framebufferPoint
        view.connection?.mouseMove(x: point.x, y: point.y)
        warpCursorToTrackedPosition()
    }

    /// Move the drawn cursor to where the remote pointer now is. The pointer is
    /// decoupled, so this only repositions what is on screen — no hardware
    /// movement is generated and the next delta is still a real one.
    private func warpCursorToTrackedPosition() {
        guard let view, let window = view.window else { return }
        let inView = Self.viewPoint(of: pointer.position, in: view)
        let onScreen = window.convertPoint(toScreen: view.convert(inView, to: nil))
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primaryTop - onScreen.y))
    }

    func button(_ button: VNCMouseButton, isDown: Bool) {
        guard let connection = view?.connection else { return }
        let point = pointer.framebufferPoint
        if isDown {
            connection.mouseButtonDown(button, x: point.x, y: point.y)
        } else {
            connection.mouseButtonUp(button, x: point.x, y: point.y)
        }
    }

    func scroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard let connection = view?.connection else { return }
        let point = pointer.framebufferPoint
        // A VNC wheel event is one click of a notched wheel, so a trackpad's
        // continuous scroll has to be quantised — and a flick must not turn
        // into hundreds of clicks.
        func steps(_ delta: CGFloat) -> UInt32 {
            UInt32(min(abs(delta) / 10, 10).rounded(.up))
        }
        if abs(deltaY) >= 1 {
            connection.mouseWheel(deltaY > 0 ? .up : .down,
                                  x: point.x, y: point.y, steps: steps(deltaY))
        }
        if abs(deltaX) >= 1 {
            connection.mouseWheel(deltaX > 0 ? .left : .right,
                                  x: point.x, y: point.y, steps: steps(deltaX))
        }
    }

    // MARK: - teardown

    func end() {
        // Leave the cursor where the remote pointer was, then hand it back to
        // the hardware: re-associating from anywhere else would teleport it.
        warpCursorToTrackedPosition()
        CGAssociateMouseAndMouseCursorPosition(1)
        if let window = view?.window, let restoreMouseMoved {
            window.acceptsMouseMovedEvents = restoreMouseMoved
        }
    }

    // MARK: - coordinates
    //
    // `contentRect` is in the flipped space RoyalVNC maps clicks through (top
    // -left origin), while an NSView's own points count up from the bottom, so
    // every conversion between the two flips y once.

    private static func framebufferPoint(of viewPoint: CGPoint,
                                         in view: VNCCAFramebufferView) -> CGPoint {
        let rect = view.contentRect
        let scale = view.scaleRatio > 0 ? view.scaleRatio : 1
        let flippedY = view.bounds.height - viewPoint.y
        return CGPoint(x: (viewPoint.x - rect.origin.x) / scale,
                       y: (flippedY - rect.origin.y) / scale)
    }

    private static func viewPoint(of framebufferPoint: CGPoint,
                                  in view: VNCCAFramebufferView) -> CGPoint {
        let rect = view.contentRect
        let scale = view.scaleRatio > 0 ? view.scaleRatio : 1
        return CGPoint(x: rect.origin.x + framebufferPoint.x * scale,
                       y: view.bounds.height - (rect.origin.y + framebufferPoint.y * scale))
    }
}

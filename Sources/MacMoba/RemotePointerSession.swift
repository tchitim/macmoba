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
// The catch is that the cursor you see over a VNC session is the local
// NSCursor — RoyalVNC hard-codes the cursor pseudo-encoding, so the server
// draws no pointer into the framebuffer and rendering it is the client's job.
// Hiding the local cursor therefore leaves the remote with nothing visible, so
// the same cursor image is drawn here instead, at the position we are tracking.

import AppKit
import MacMobaCore
import RoyalVNCKit

@MainActor
final class RemotePointerSession {
    private weak var view: VNCCAFramebufferView?
    private var pointer: RelativePointer
    private let cursorLayer = RemoteCursorView()
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
        NSCursor.hide()
        view.addSubview(cursorLayer)
        redrawCursor()
    }

    // MARK: - input

    func move(dx: CGFloat, dy: CGFloat) {
        guard let view else { return }
        // AppKit's deltaY grows downwards, which is also how the framebuffer
        // counts rows, so it passes through unflipped.
        pointer.move(dx: dx, dy: dy, scale: view.scaleRatio)
        let point = pointer.framebufferPoint
        view.connection?.mouseMove(x: point.x, y: point.y)
        redrawCursor()
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
        cursorLayer.removeFromSuperview()
        NSCursor.unhide()
        CGAssociateMouseAndMouseCursorPosition(1)
        if let view, let window = view.window {
            if let restoreMouseMoved { window.acceptsMouseMovedEvents = restoreMouseMoved }
            // Put the real cursor where the remote one was left, so releasing
            // does not teleport it back to wherever the grab started.
            let inView = Self.viewPoint(of: pointer.position, in: view)
            let onScreen = window.convertPoint(toScreen: view.convert(inView, to: nil))
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primaryTop - onScreen.y))
        }
    }

    // MARK: - drawing the remote cursor

    private func redrawCursor() {
        guard let view else { return }
        let cursor = view.currentCursor
        let image = cursor.image
        if cursorLayer.image !== image { cursorLayer.image = image }
        let point = Self.viewPoint(of: pointer.position, in: view)
        // `hotSpot` is measured from the image's top-left; the view's origin is
        // its bottom-left.
        cursorLayer.frame = CGRect(x: point.x - cursor.hotSpot.x,
                                   y: point.y - (image.size.height - cursor.hotSpot.y),
                                   width: image.size.width, height: image.size.height)
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

/// The remote cursor, drawn by us because the real one is hidden. Transparent
/// to the mouse — it sits under the pointer by definition, so hit-testing it
/// would swallow every click.
private final class RemoteCursorView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleNone
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

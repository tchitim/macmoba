// Typing into a remote desktop, and capturing input for one.
//
// TRANSLATION. RoyalVNC turns a key press into an X11 keysym via
// `event.charactersIgnoringModifiers`, which AppKit resolves through the
// current input source. Select a Cangjie/Sucheng input method and that stops
// being "a": the library then either finds no keysym and drops the key, or
// sends the composed character's raw Unicode value as a keysym — which is not
// how X11 encodes Unicode, so the remote receives noise. Either way the remote
// Mac's own input method never sees the keys it needs to compose with. So the
// physical key is translated here through the ASCII-capable layout instead.
//
// CAPTURE. Clicking into a remote desktop hands it the keyboard and pins the
// pointer inside it, the way VMware and Parallels do — including the keys this
// Mac would otherwise keep for itself, which is what lets you switch the
// REMOTE input source with ⌃Space. Press Escape twice to let go.
//
// Both live on one local event monitor because it runs before the event
// reaches the window: that is what lets us forward a key AND keep the local
// input method from opening a composition over a session it cannot type into.

@preconcurrency import AppKit
import Carbon
import Combine
import MacMobaCore
import RoyalVNCKit

@MainActor
final class VNCKeyboardBridge: ObservableObject {
    /// Whether input is currently captured, for the pane's on-screen hint.
    @Published private(set) var isGrabbed = false
    /// Turns the click-to-capture behaviour off entirely (Session menu). The
    /// escape hatch for anyone who does not want VMware's grammar.
    @Published var capturesOnClick: Bool =
        UserDefaults.standard.object(forKey: "vncCapturesOnClick") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(capturesOnClick, forKey: "vncCapturesOnClick")
            if !capturesOnClick { release() }
        }
    }

    private var monitor: Any?
    private weak var grabbedView: VNCCAFramebufferView?
    /// Present exactly while the pointer is decoupled and we are driving the
    /// remote one ourselves.
    private var pointer: RemotePointerSession?
    /// A capture that focus loss interrupted, waiting to be picked back up.
    private weak var suspended: VNCCAFramebufferView?
    private var previousHotKeyMode: UnsafeMutableRawPointer?
    private var escapeGesture = DoubleEscapeRelease()
    private var observers: [NSObjectProtocol] = []

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp,
                       .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                       .otherMouseDown, .otherMouseUp,
                       .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                       .scrollWheel]
        ) { [weak self] event in
            // Unwrapped in two steps on purpose. `self?.handle(event) ?? event`
            // reads the same but is not: optional chaining flattens "no bridge"
            // and "handled, swallow it" into one nil, so `?? event` puts a key
            // we already sent back into the responder chain — and the remote
            // receives it twice.
            guard let self else { return event }
            return self.handle(event)
        }
        // Losing focus must drop the grab, or a capture survives ⌘Tab and the
        // keyboard appears dead in whatever the user switched to. It is only
        // suspended, though: something else stealing focus for a moment should
        // not cost the session, so coming back restores it.
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendGrab() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeGrabIfSuspended() }
            })
        }
    }

    /// A new cursor from the server. While input is captured the real cursor is
    /// hidden and a copy is drawn, so the copy has to be told.
    func remoteCursorChanged(_ cursor: VNCCursor) {
        guard let pointer, let image = cursor.cgImage else { return }
        pointer.updateCursor(image: image, size: cursor.cgSize, hotSpot: cursor.cgHotspot)
    }

    /// Public release, for the menu and for turning capture off. Deliberate, so
    /// it does not come back on its own.
    func release() {
        suspended = nil
        releaseGrab()
    }

    // MARK: - the monitor

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown, .keyUp: return handleKey(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return handleMouseDown(event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return handleMouseUp(event)
        case .scrollWheel: return handleScroll(event)
        default: return handlePointerMove(event)
        }
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        if let pointer {
            pointer.button(button(for: event), isDown: true)
            return nil
        }
        guard capturesOnClick, !isGrabbed, event.type == .leftMouseDown,
              let window = event.window,
              let view = window.contentView?.hitTest(event.locationInWindow) as? VNCCAFramebufferView
        else { return event }
        grab(view, at: view.convert(event.locationInWindow, from: nil))
        // The click that captured input is also a click on the remote desktop.
        // Once the pointer is decoupled the library can no longer read it off
        // the cursor, so it is sent here instead.
        if let pointer {
            pointer.button(.left, isDown: true)
            return nil
        }
        return event
    }

    private func handleMouseUp(_ event: NSEvent) -> NSEvent? {
        guard let pointer else { return event }
        pointer.button(button(for: event), isDown: false)
        return nil
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let pointer else { return event }
        pointer.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        return nil
    }

    private func button(for event: NSEvent) -> VNCMouseButton {
        switch event.type {
        case .rightMouseDown, .rightMouseUp: return .right
        case .otherMouseDown, .otherMouseUp: return .middle
        default: return .left
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Escape is checked BEFORE anything else, and without asking who the
        // first responder is. It is the only way out of a capture — the pointer
        // is captured too, so the menu bar cannot be reached — and a way out
        // that depends on other state being right is not a way out. It also
        // stays on the library's key-code path, so the remote receives every
        // press; we only watch the timing.
        if event.keyCode == UInt16(kVK_Escape) {
            if event.type == .keyDown, isGrabbed {
                let released = event.isARepeat
                    ? escapeGesture.escapeHeld(at: event.timestamp)
                    : escapeGesture.escapePressed(at: event.timestamp)
                if released { releaseGrab() }
            }
            return event
        }

        guard let view = NSApp.keyWindow?.firstResponder as? VNCCAFramebufferView,
              let connection = view.connection else { return event }

        let flags = event.modifierFlags
        let character = ASCIIKeyboard.character(forKeyCode: event.keyCode,
                                                shift: flags.contains(.shift),
                                                capsLock: flags.contains(.capsLock))
        guard RemoteKeyPolicy.sendsPhysicalKey(command: flags.contains(.command),
                                               control: flags.contains(.control),
                                               option: flags.contains(.option),
                                               function: flags.contains(.function),
                                               character: character,
                                               // We only get here with a remote
                                               // desktop focused, and in that
                                               // state the library already
                                               // forwards ⌘ chords to it — so
                                               // ⌘C is the remote's, captured
                                               // or not, and must arrive right.
                                               modifiersGoToRemote: true),
              let character else { return event }

        let keys = VNCKeyCode.keyCodesFrom(characters: character)
        guard !keys.isEmpty else { return event }
        for key in keys {
            if event.type == .keyDown {
                connection.keyDown(key)
            } else {
                connection.keyUp(key)
            }
        }
        return nil
    }

    /// While captured the pointer is decoupled from the display, so the cursor
    /// position means nothing and only the movement does: it drives a pointer
    /// tracked in the remote screen's own coordinates.
    private func handlePointerMove(_ event: NSEvent) -> NSEvent? {
        guard let pointer else { return event }
        pointer.move(dx: event.deltaX, dy: event.deltaY)
        return nil
    }

    // MARK: - grab lifecycle

    private func grab(_ view: VNCCAFramebufferView, at viewPoint: CGPoint) {
        grabbedView = view
        escapeGesture.reset()
        isGrabbed = true
        pointer = RemotePointerSession(view: view, startingAt: viewPoint)
        // Suppressing this Mac's own hot keys — ⌘Tab, Spotlight, the input
        // source switch — is what makes the remote reachable with them. macOS
        // only allows it for a trusted process; without permission the capture
        // still keeps the local input method out of the way and pins the
        // pointer, which is most of the value.
        if AXIsProcessTrusted() {
            previousHotKeyMode = PushSymbolicHotKeyMode(UInt32(kHIHotKeyModeAllDisabled))
        } else {
            askForAccessibilityOnce()
        }
    }

    /// Ask for Accessibility the first time input is captured, and never again:
    /// the capture works without it (the pointer is still pinned, the local
    /// input method still stays out of the way), so nagging would be rude —
    /// but ⌃Space and ⌘Tab cannot reach the remote until it is granted.
    private func askForAccessibilityOnce() {
        let key = "askedAccessibilityForCapture"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Give the keyboard back because something else took focus, remembering
    /// where we were so that returning picks it up again.
    private func suspendGrab() {
        guard isGrabbed, let grabbedView else { return }
        suspended = grabbedView
        releaseGrab()
    }

    private func resumeGrabIfSuspended() {
        guard let view = suspended, !isGrabbed, capturesOnClick else { return }
        // Only if that pane is still the one in front: the user may have come
        // back to a different tab or window entirely.
        guard NSApp.isActive, NSApp.keyWindow?.firstResponder === view else { return }
        suspended = nil
        // Resume where the pointer was, not where the cursor happens to sit.
        grab(view, at: view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero,
                                    from: nil))
    }

    private func releaseGrab() {
        guard isGrabbed else { return }
        pointer?.end()
        pointer = nil
        if let previousHotKeyMode {
            PopSymbolicHotKeyMode(previousHotKeyMode)
            self.previousHotKeyMode = nil
        }
        grabbedView = nil
        escapeGesture.reset()
        isGrabbed = false
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

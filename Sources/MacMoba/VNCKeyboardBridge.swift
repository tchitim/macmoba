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
    private var previousHotKeyMode: UnsafeMutableRawPointer?
    private var escapeGesture = DoubleEscapeRelease()
    private var observers: [NSObjectProtocol] = []

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .leftMouseDown, .mouseMoved, .leftMouseDragged,
                       .rightMouseDragged, .otherMouseDragged]
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
        // keyboard appears dead in whatever the user switched to.
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseGrab() }
            })
        }
    }

    /// Public release, for the menu and for turning capture off.
    func release() { releaseGrab() }

    // MARK: - the monitor

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown: return handleMouseDown(event)
        case .keyDown, .keyUp: return handleKey(event)
        default: return handlePointerMove(event)
        }
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard capturesOnClick, !isGrabbed,
              let window = event.window,
              let view = window.contentView?.hitTest(event.locationInWindow) as? VNCCAFramebufferView
        else { return event }
        grab(view)
        return event   // the click itself still belongs to the remote
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let view = NSApp.keyWindow?.firstResponder as? VNCCAFramebufferView,
              let connection = view.connection else { return event }

        // Escape stays on the library's key-code path so the remote always
        // receives it; we only watch the timing.
        if event.keyCode == UInt16(kVK_Escape) {
            if event.type == .keyDown, isGrabbed, escapeGesture.escapePressed(at: event.timestamp) {
                releaseGrab()
            }
            return event
        }

        let flags = event.modifierFlags
        let character = ASCIIKeyboard.character(forKeyCode: event.keyCode,
                                                shift: flags.contains(.shift),
                                                capsLock: flags.contains(.capsLock))
        guard RemoteKeyPolicy.sendsPhysicalKey(command: flags.contains(.command),
                                               control: flags.contains(.control),
                                               option: flags.contains(.option),
                                               function: flags.contains(.function),
                                               character: character,
                                               grabbed: isGrabbed && grabbedView === view),
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

    /// Keep the pointer inside the captured desktop. Warping it back at the
    /// edge is cheaper than true relative mode, which would mean hiding the
    /// cursor — and the cursor IS the remote one here (RoyalVNC renders it as
    /// an NSCursor), so hiding it would leave the remote with no pointer at all.
    private func handlePointerMove(_ event: NSEvent) -> NSEvent? {
        guard isGrabbed, let view = grabbedView, let window = view.window else { return event }
        let onScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        let location = NSEvent.mouseLocation
        guard !onScreen.contains(location) else { return event }
        let clamped = PointerClamp.clamp(location, to: onScreen)
        CGWarpMouseCursorPosition(flippedToGlobal(clamped))
        // Swallowed: forwarding a position we just refused would jump the
        // remote cursor to the edge we are holding it away from.
        return nil
    }

    /// AppKit screen coordinates are bottom-left origin; Core Graphics global
    /// display coordinates are top-left, measured from the primary screen.
    private func flippedToGlobal(_ point: CGPoint) -> CGPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: primaryTop - point.y)
    }

    // MARK: - grab lifecycle

    private func grab(_ view: VNCCAFramebufferView) {
        grabbedView = view
        escapeGesture.reset()
        isGrabbed = true
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

    private func releaseGrab() {
        guard isGrabbed else { return }
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

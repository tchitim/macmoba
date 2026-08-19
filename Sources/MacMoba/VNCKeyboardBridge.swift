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
    /// What the last paste-by-typing did, for the diagnostics report: telling
    /// "never triggered" from "sent, and the remote ignored it" is otherwise
    /// guesswork.
    private(set) var lastTypedKeyCount: Int?
    private var previousHotKeyMode: UnsafeMutableRawPointer?
    private var escapeGesture = DoubleEscapeRelease()
    private var chordGesture = ModifierChordRelease()
    /// Which gesture lets go of the keyboard. ⌃⌥ by default because Escape
    /// twice, while easier to remember, is also a gesture the REMOTE may want:
    /// Claude Code reads it as "go back a message", and both presses are
    /// forwarded on purpose so Escape keeps working over there.
    @Published var releasesWithEscape: Bool =
        UserDefaults.standard.bool(forKey: "vncReleasesWithEscape") {
        didSet { UserDefaults.standard.set(releasesWithEscape, forKey: "vncReleasesWithEscape") }
    }

    /// What to tell the user on screen, so the hint always matches the setting.
    var releaseHint: String {
        releasesWithEscape ? "press Esc twice to release" : "press ⌃⌥ to release"
    }
    private var observers: [NSObjectProtocol] = []

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp,
                       .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                       .otherMouseDown, .otherMouseUp,
                       .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                       .scrollWheel, .flagsChanged]
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

    /// Where the keyboard is actually pointing. Every key we handle depends on
    /// a remote desktop being the first responder, so when "nothing happens"
    /// this is the first thing worth knowing — and it cannot be seen from
    /// outside the app.
    var focusReport: String {
        let responder = NSApp.keyWindow?.firstResponder
        let name = responder.map { String(describing: type(of: $0)) } ?? "none"
        return """
        key window: \(NSApp.keyWindow == nil ? "none" : "yes")
        app active: \(NSApp.isActive)
        first responder: \(name)
        remote desktop is first responder: \(responder is VNCCAFramebufferView)
        remote desktop found in window: \(focusedFramebufferView != nil)
        event monitor installed: \(monitor != nil)
        capture on click: \(capturesOnClick) · captured now: \(isGrabbed)
        release gesture: \(releasesWithEscape ? "Esc Esc" : "Control-Option")
        """
    }

    /// Type what is on the clipboard into the focused remote desktop.
    ///
    /// Paced deliberately: a remote Mac processes synthesised keys through the
    /// same path as a physical keyboard, and a burst arriving in one frame gets
    /// dropped or reordered. A few milliseconds per key is imperceptible for a
    /// password or a command and reliable for a paragraph.
    func typeClipboard(into connection: VNCConnection) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let keysyms = RemoteTyping.keysyms(for: text)
        lastTypedKeyCount = keysyms.count
        guard !keysyms.isEmpty else { return }
        Task {
            for keysym in keysyms {
                let key = VNCKeyCode(keysym)
                connection.keyDown(key)
                connection.keyUp(key)
                try? await Task.sleep(nanoseconds: 6_000_000)
            }
        }
    }

    /// Types the clipboard into whichever remote desktop is in front, for the
    /// menu — the keyboard route needs one to be focused, and this does not.
    func typeClipboardIntoFocusedDesktop() -> Bool {
        guard let view = focusedFramebufferView, let connection = view.connection else { return false }
        typeClipboard(into: connection)
        return true
    }

    /// The remote desktop to act on. Focus first, then the windows themselves —
    /// `keyWindow` is nil while a menu is still closing, which is exactly when
    /// a menu item runs, and there can be more than one window anyway. Looking
    /// only there reported "no remote desktop" with one plainly on screen.
    private var focusedFramebufferView: VNCCAFramebufferView? {
        if let view = NSApp.keyWindow?.firstResponder as? VNCCAFramebufferView { return view }
        var searched: [NSWindow] = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        searched.append(contentsOf: NSApp.windows.filter { $0.isVisible })
        for window in searched {
            if let view = window.contentView.flatMap(Self.findFramebufferView) { return view }
        }
        return nil
    }

    private static func findFramebufferView(in view: NSView) -> VNCCAFramebufferView? {
        if let match = view as? VNCCAFramebufferView { return match }
        for subview in view.subviews {
            if let match = findFramebufferView(in: subview) { return match }
        }
        return nil
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
        // A capture outlives its desktop if the user switches tabs: SwiftUI
        // takes the view out of the window, nothing here notices, and every
        // click in the app keeps being swallowed on behalf of a remote desktop
        // that is no longer on screen — which is how copying from a web tab
        // stopped working.
        if isGrabbed, grabbedView?.window == nil { releaseGrab() }

        switch event.type {
        case .keyDown, .keyUp: return handleKey(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return handleMouseDown(event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return handleMouseUp(event)
        case .scrollWheel: return handleScroll(event)
        case .flagsChanged: return handleFlagsChanged(event)
        default: return handlePointerMove(event)
        }
    }

    /// The ⌃⌥ release. Modifier changes are watched even when not captured —
    /// harmlessly, since the gesture only does anything to a live capture.
    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags
        let held = flags.contains(.control) && flags.contains(.option)
            && !flags.contains(.command) && !flags.contains(.shift)
        if chordGesture.modifiersChanged(held: held), isGrabbed, !releasesWithEscape {
            releaseGrab()
        }
        return event
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
        // The library takes focus in its own mouseDown, which we are about to
        // swallow — so clicking back into a remote desktop after using the
        // sidebar would leave the keyboard pointing at nothing.
        window.makeFirstResponder(view)
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
        // Any key cancels a half-made ⌃⌥ gesture: that combination plus a
        // letter is a shortcut, and the remote should get it.
        if event.type == .keyDown { chordGesture.otherKeyPressed() }

        if event.keyCode == UInt16(kVK_Escape) {
            if event.type == .keyDown, isGrabbed, releasesWithEscape {
                let released = event.isARepeat
                    ? escapeGesture.escapeHeld(at: event.timestamp)
                    : escapeGesture.escapePressed(at: event.timestamp)
                if released { releaseGrab() }
            }
            return event
        }

        // ⌥⌘V types the clipboard into the remote, because it cannot get there
        // by itself: macOS's VNC server ignores the standard clipboard message
        // (Apple's own Screen Sharing syncs over a private extension), and that
        // message carries Latin-1 only. Kept out of the forwarding path — the
        // remote never receives this one chord — so it still works while input
        // is captured, which is when the menu bar is out of reach. Checked
        // before the focus guard below, and against the whole window: a paste
        // that only works when focus happens to be right is not much of one.
        if event.modifierFlags.contains([.command, .option]),
           ASCIIKeyboard.character(forKeyCode: event.keyCode, shift: false) == "v",
           let desktop = focusedFramebufferView, let target = desktop.connection {
            if event.type == .keyDown { typeClipboard(into: target) }
            return nil
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
        chordGesture.reset()
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

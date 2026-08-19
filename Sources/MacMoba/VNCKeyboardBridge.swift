// Typing into a remote desktop, whatever input method is selected here.
//
// RoyalVNC turns a key press into an X11 keysym via
// `event.charactersIgnoringModifiers`, which AppKit resolves through the
// current input source. Select a Cangjie/Sucheng input method and that stops
// being "a": the library then either finds no keysym and drops the key, or
// sends the composed character's raw Unicode value as a keysym — which is not
// how X11 encodes Unicode, so the remote receives noise. Either way the remote
// Mac's own input method never sees the keys it needs to compose with.
//
// A local event monitor runs before the event reaches the window, so this both
// forwards the right key AND keeps the local input method from opening a
// composition of its own over a session it cannot type into. Only plain typing
// is taken over; ⌘/⌃/⌥ chords and the arrows stay on the library's paths,
// which are already input-source blind because they travel by key code.

@preconcurrency import AppKit
import MacMobaCore
import RoyalVNCKit

@MainActor
final class VNCKeyboardBridge {
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            VNCKeyboardBridge.forward(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Returns nil when the key has been sent to the remote desktop — swallowing
    /// it here is what keeps the local input method out of the way.
    private static func forward(_ event: NSEvent) -> NSEvent? {
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
                                               character: character),
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
}

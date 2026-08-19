// What a physical key means, independent of the input method in use.
//
// Controlling a remote desktop means the REMOTE machine's input method does
// the composing: you press the keys, its 倉頡/注音/Pinyin engine turns them
// into characters. That only works if the client forwards the physical key.
//
// AppKit's `charactersIgnoringModifiers` cannot do that job, because it is
// resolved through whichever input source is selected here — pick a Cangjie
// variant on the laptop and the same key stops reporting "a". A VNC client
// that reads keys that way sends the remote something it cannot use, and the
// remote's own input method never gets a chance to compose.
//
// So ask the ASCII-capable layout instead: it exists precisely for this, and
// Text Input Services keeps returning it while an input method is selected.

import Foundation

#if canImport(Carbon)
import Carbon
#endif

public enum ASCIIKeyboard {
    /// The character a physical key produces under the ASCII-capable keyboard
    /// layout, or nil when the key has no printable meaning there (Return,
    /// Escape, the arrows — those carry their own key codes and do not need
    /// translating).
    ///
    /// Dead keys are resolved immediately rather than accumulating state: a
    /// remote desktop wants each press forwarded as it happens.
    public static func character(forKeyCode keyCode: UInt16,
                                 shift: Bool,
                                 capsLock: Bool = false) -> String? {
        #if canImport(Carbon)
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            // Carbon wants the modifier bits in the high byte shifted down.
            let modifiers = UInt32(((shift ? shiftKey : 0) | (capsLock ? alphaLock : 0)) >> 8)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), modifiers,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
        #else
        return nil
        #endif
    }
}

/// Which key presses MacMoba translates itself before handing them to a remote
/// desktop, rather than letting the library read them off the current input
/// source. Split out from the Carbon lookup so the rule is testable on its own.
public enum RemoteKeyPolicy {
    /// True when `character` is an ordinary typed character that should be
    /// forwarded as the physical key.
    ///
    /// `function` covers the arrows, F-keys and friends, which travel by key
    /// code and are already input-source blind. Anything unprintable (Return,
    /// Escape, Tab) likewise has its own key code, so there is nothing to gain
    /// by rewriting it here — and Escape in particular must stay on that path,
    /// because it is also the release gesture.
    ///
    /// Modifier chords are only taken over when they are the remote's to
    /// receive — which, for a focused remote desktop, they already are: the
    /// library consumes ⌘ chords and forwards them, so ⌘C has not reached
    /// MacMoba's own menus for a long time. Translating them here changes
    /// nothing about where they go and fixes what arrives, for exactly the
    /// reason plain typing needed fixing. Where the remote does NOT own them,
    /// swallowing them would eat the app's own key equivalents.
    public static func sendsPhysicalKey(command: Bool,
                                        control: Bool,
                                        option: Bool,
                                        function: Bool,
                                        character: String?,
                                        modifiersGoToRemote: Bool = false) -> Bool {
        guard !function else { return false }
        if !modifiersGoToRemote {
            guard !command, !control, !option else { return false }
        }
        guard let character, character.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        // Printable ASCII only. A non-ASCII result would mean the lookup found
        // something other than an ASCII layout, and forwarding it would hit the
        // same broken path we are avoiding.
        return (0x20...0x7e).contains(scalar.value)
    }
}

// Typing text into a remote desktop, one key at a time.
//
// The clipboard cannot get there on its own. RFB's clipboard message carries
// Latin-1 and nothing else, and macOS's own VNC server ignores it anyway —
// Apple's Screen Sharing app syncs the clipboard over an extension of its own,
// which is why it works and a standards-conformant client does not.
//
// So paste by typing. X11 has a keysym for any Unicode scalar — 0x01000000
// plus the code point — which is how a remote desktop is told about a
// character that no physical key produces, and it makes Chinese work where the
// clipboard message could not have carried it at all.

import Foundation

public enum RemoteTyping {
    /// X11 keysyms for `text`, in the order they should be pressed.
    ///
    /// Newlines become Return and tabs become Tab, because a remote text field
    /// wants the key, not the character. Other control characters are dropped:
    /// they are invisible in the source and unpredictable at the far end.
    public static func keysyms(for text: String) -> [UInt32] {
        var keysyms: [UInt32] = []
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r":
                keysyms.append(0xFF0D)               // XK_Return
            case "\t":
                keysyms.append(0xFF09)               // XK_Tab
            case let scalar where scalar.value < 0x20 || scalar.value == 0x7f:
                continue                             // other control characters
            case let scalar where scalar.value < 0x80:
                keysyms.append(scalar.value)         // ASCII is its own keysym
            default:
                // The Unicode keysym range. Sending the bare code point — what
                // a naive client does — lands in the middle of the legacy
                // keysym table and produces something else entirely.
                keysyms.append(0x0100_0000 + scalar.value)
            }
        }
        return keysyms
    }
}

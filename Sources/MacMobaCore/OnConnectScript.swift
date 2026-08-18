// Turning a session's "run these when I connect" text into the exact bytes to
// type into the shell.
//
// A terminal expects Return as CR — sending LF would land mid-line in most
// shells — so every line break becomes CR, and a trailing CR is added so the
// last command actually runs rather than sitting on the prompt. This mirrors
// MacroConfig.keystrokes; it lives on its own so the on-connect behaviour can
// be tested without standing up a terminal.

import Foundation

public enum OnConnectScript {
    /// The characters to type after connecting, or "" when there is nothing to
    /// run (nil, empty, or only whitespace).
    public static func keystrokes(_ script: String?) -> String {
        guard let script,
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        var text = script
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        if !text.hasSuffix("\r") { text += "\r" }
        return text
    }
}

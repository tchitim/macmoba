// Which saved session can run a command on the machine you are looking at.
//
// A remote desktop cannot hand its clipboard back: macOS's VNC server never
// sends one, and the protocol offers no way to ask. But the same machine is
// usually reachable another way — people who run a desktop session on a box
// generally have a shell session on it too — and a shell can simply be asked
// what is on the clipboard.
//
// So the missing direction is not missing at all; it just travels over a
// different session. This picks which one.

import Foundation

public enum RemoteShellMatch {
    /// The best saved SSH session for `host`, or nil if there is none.
    ///
    /// Matching is by host, not by name: the two sessions describe the same
    /// machine and are unlikely to be called the same thing. A session that
    /// cannot run a command — a desktop, a serial line, a web page — is never
    /// a candidate, however well its host matches.
    public static func session(forHost host: String,
                               in sessions: [SessionConfig]) -> SessionConfig? {
        let wanted = normalized(host)
        guard !wanted.isEmpty else { return nil }
        return sessions.first { candidate in
            candidate.sessionKind == .ssh && normalized(candidate.host) == wanted
        }
    }

    private static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Read the clipboard of a remote machine. macOS answers with `pbpaste`;
    /// the X11 tools are tried after it so the same command serves a Linux
    /// desktop, and the whole thing stays quiet when none of them exist.
    public static let readClipboardCommand =
        "pbpaste 2>/dev/null || xclip -o -selection clipboard 2>/dev/null || xsel -b 2>/dev/null"
}

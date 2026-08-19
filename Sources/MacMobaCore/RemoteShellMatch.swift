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
        let shells = sessions.filter { $0.sessionKind == .ssh && !$0.host.isEmpty }
        if let exact = shells.first(where: { normalized($0.host) == wanted }) { return exact }
        // The same machine is often written two ways — `mac-mini.local` in one
        // session and `mac-mini` in the other — so fall back to the first label.
        let wantedLabel = firstLabel(wanted)
        guard !wantedLabel.isEmpty else { return nil }
        return shells.first { firstLabel(normalized($0.host)) == wantedLabel }
    }

    /// Every session that could run the command, for a caller that wants to
    /// resolve addresses when neither the host nor its short name matches.
    public static func shellSessions(in sessions: [SessionConfig]) -> [SessionConfig] {
        sessions.filter { $0.sessionKind == .ssh && !$0.host.isEmpty }
    }

    private static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The first label of a host name, and nothing for a literal address — the
    /// first label of `192.168.1.10` is `192`, which would match half a subnet.
    private static func firstLabel(_ host: String) -> String {
        guard host.contains(where: { $0.isLetter }) else { return "" }
        return String(host.prefix { $0 != "." })
    }

    /// Read the clipboard of a remote machine. macOS answers with `pbpaste`;
    /// the X11 tools are tried after it so the same command serves a Linux
    /// desktop, and the whole thing stays quiet when none of them exist.
    ///
    /// `LC_ALL` matters: `pbpaste` encodes its output for the current locale,
    /// and an exec channel carries no TTY and usually no locale at all, so
    /// anything outside ASCII comes back as question marks — Chinese arrives
    /// as `????`.
    public static let readClipboardCommand =
        "LC_ALL=en_US.UTF-8 pbpaste 2>/dev/null"
        + " || xclip -o -selection clipboard 2>/dev/null || xsel -b 2>/dev/null"
}

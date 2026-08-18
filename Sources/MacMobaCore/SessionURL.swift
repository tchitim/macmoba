// "Click this link to connect." A URL like ssh://user@host:2222 should open a
// session, the way Terminal, PuTTY and Royal TSX all register their schemes.
//
// This is only the parser — turning a URL into a `SessionConfig`. Registering
// the schemes and acting on an opened URL is the app's job; keeping the parse
// here means it is testable without launching anything, and the same code
// handles a link clicked in a browser, one passed on the command line, and one
// typed into a "quick connect" box.

import Foundation

public enum SessionURL {
    /// Schemes we answer to, mapped to what they mean. `sftp` is SSH with the
    /// file browser in mind but connects the same way, so it lands on SSH.
    static let schemeKinds: [String: SessionKind] = [
        "ssh": .ssh,
        "sftp": .ssh,
        "mosh": .mosh,
        "telnet": .telnet,
        "ftp": .ftp,
        "vnc": .vnc,
        "rdp": .rdp,
    ]

    public static var supportedSchemes: [String] { Array(schemeKinds.keys).sorted() }

    /// Parse a connection URL into a ready-to-open session, or nil if the scheme
    /// is not one of ours or there is no host. The session is transient (a fresh
    /// id, no group); the caller decides whether to also save it.
    public static func parse(_ string: String) -> SessionConfig? {
        // URLComponents keeps percent-decoding correct for user/password.
        guard let comps = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = comps.scheme?.lowercased(),
              let kind = schemeKinds[scheme] else { return nil }
        return parse(components: comps, kind: kind)
    }

    public static func parse(_ url: URL) -> SessionConfig? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(),
              let kind = schemeKinds[scheme] else { return nil }
        return parse(components: comps, kind: kind)
    }

    private static func parse(components comps: URLComponents, kind: SessionKind) -> SessionConfig? {
        guard let host = comps.host, !host.isEmpty else { return nil }
        let port = comps.port ?? kind.defaultPort
        let user = comps.user ?? ""
        // A password in the URL is convenience, not security; keep it if given
        // but never require it.
        let password = comps.password
        // vnc://host/2  — some clients put the display number in the path.
        let name = user.isEmpty ? host : "\(user)@\(host)"

        return SessionConfig(
            name: name,
            host: host,
            port: port,
            username: user,
            authType: "password",
            password: (password?.isEmpty == false) ? password : nil,
            kind: kind.rawValue)
    }
}

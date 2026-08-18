// X11 forwarding — opening a remote GUI app so its window appears on the Mac.
//
// The honest situation first: real ssh X11 forwarding needs the server to open
// an "x11" channel back to us, and swift-nio-ssh does not model that channel
// type — it rejects any channel that is not session / direct-tcpip /
// forwarded-tcpip at the parser (SSHMessages.swift). So native `x11-req`
// forwarding is impossible on this SSH stack, the same way ssh-agent and
// keyboard-interactive are.
//
// The achievable equivalent, built here, is X11 over a *remote* forward, which
// NIOSSH does support: ask the server to listen on 127.0.0.1:(6000+N), forward
// those connections back to the Mac's X server, and set DISPLAY=localhost:N on
// the remote. A remote GUI app then connects to the server's local X port,
// which tunnels to XQuartz here. This needs XQuartz running with TCP listening
// enabled (`defaults write org.xquartz.X11 nolisten_tcp -bool false`).
//
// Only the pure pieces live here — port math, DISPLAY parsing, .Xauthority
// cookie extraction, the remote setup commands, and the tunnel config — so they
// are unit-testable without an X server. The byte plumbing reuses the tested
// RemoteForward.

import Foundation

public enum X11Forwarding {
    /// X displays map to TCP ports at a fixed offset: display N is port 6000+N.
    public static let baseTCPPort = 6000

    /// A display number chosen high enough to avoid a real local display. ssh
    /// itself starts at 10 for the same reason.
    public static let defaultRemoteDisplay = 10

    public static func port(forDisplay display: Int) -> Int { baseTCPPort + display }

    /// What to set the remote DISPLAY to for `display`.
    public static func displayString(_ display: Int, screen: Int = 0) -> String {
        "localhost:\(display).\(screen)"
    }

    /// The display number out of a DISPLAY value: `:0`, `localhost:10.0`,
    /// `host:11` → 0, 10, 11. Nil if there is no `:n`.
    public static func displayNumber(from display: String) -> Int? {
        guard let colon = display.lastIndex(of: ":") else { return nil }
        let after = display[display.index(after: colon)...]
        let numberPart = after.prefix(while: { $0 != "." })
        return Int(numberPart)
    }

    /// The remote-forward config that makes the server listen on
    /// 127.0.0.1:(6000+display) and tunnel back to the Mac's X server TCP port.
    public static func remoteForwardConfig(sessionId: String, display: Int,
                                           localX11Port: Int = baseTCPPort) -> TunnelConfig {
        TunnelConfig(
            name: "X11 :\(display)",
            type: "remote",
            sessionId: sessionId,
            bindHost: "127.0.0.1",
            bindPort: port(forDisplay: display),
            targetHost: "127.0.0.1",
            targetPort: localX11Port)
    }

    /// Commands to run on the remote once connected: point DISPLAY at the
    /// tunnelled port, and (if we have the Mac's cookie) authorise it so the
    /// remote app is allowed to connect. `xauth` failures are swallowed — a
    /// trusted setup may not need it.
    public static func remoteSetup(display: Int, cookieHex: String?) -> String {
        var lines = ["export DISPLAY=\(displayString(display))"]
        if let cookieHex, !cookieHex.isEmpty {
            // `xauth add <display> <proto> <hexcookie>` — the standard way to
            // hand a cookie to the remote for this display.
            lines.append("(xauth add \(displayString(display)) MIT-MAGIC-COOKIE-1 \(cookieHex) 2>/dev/null || true)")
        }
        return lines.joined(separator: "\n")
    }
}

/// One entry in an `~/.Xauthority` file.
public struct XAuthEntry: Equatable, Sendable {
    public var family: UInt16
    public var address: String
    public var displayNumber: String
    public var name: String
    public var cookieHex: String
}

/// Reads the binary `~/.Xauthority` format so we can hand the Mac's real
/// MIT-MAGIC-COOKIE-1 to the remote. Every field is a big-endian uint16 length
/// followed by that many bytes, except `family` which is a bare uint16.
public enum XAuthority {
    public static func parse(_ data: Data) -> [XAuthEntry] {
        var entries: [XAuthEntry] = []
        var r = Reader(data)
        while let family = r.uint16() {
            guard let address = r.lengthPrefixed(),
                  let number = r.lengthPrefixed(),
                  let name = r.lengthPrefixed(),
                  let cookie = r.lengthPrefixed() else { break }
            entries.append(XAuthEntry(
                family: family,
                address: String(decoding: address, as: UTF8.self),
                displayNumber: String(decoding: number, as: UTF8.self),
                name: String(decoding: name, as: UTF8.self),
                cookieHex: cookie.map { String(format: "%02x", $0) }.joined()))
        }
        return entries
    }

    /// The MIT-MAGIC-COOKIE-1 for a given display, or the first one if none is
    /// pinned to that display (a common case where the entry uses display "0"
    /// or an empty number for the whole server).
    public static func cookie(forDisplay display: Int, in entries: [XAuthEntry]) -> String? {
        let magic = entries.filter { $0.name == "MIT-MAGIC-COOKIE-1" }
        if let exact = magic.first(where: { $0.displayNumber == String(display) }) {
            return exact.cookieHex
        }
        return magic.first?.cookieHex
    }

    private struct Reader {
        private let data: Data
        private var offset: Int
        init(_ data: Data) { self.data = Data(data); offset = 0 }

        mutating func uint16() -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            defer { offset += 2 }
            return (UInt16(data[data.startIndex + offset]) << 8)
                | UInt16(data[data.startIndex + offset + 1])
        }

        mutating func lengthPrefixed() -> Data? {
            guard let len = uint16() else { return nil }
            guard offset + Int(len) <= data.count else { return nil }
            defer { offset += Int(len) }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + Int(len)))
        }
    }
}

// The BSD rlogin wire protocol (RFC 1282) — the parts a client needs.
//
// rlogin is almost nothing: after the TCP connect the client sends one
// null-delimited handshake, the server answers with a single 0x00 byte on
// success, and from then on it is a raw byte stream. The only in-band control is
// the window-size message. Like Telnet it has no encryption, which is the whole
// reason to keep it clearly labelled.
//
// This is just the byte formats, so they can be unit-tested; RloginConnection
// is the socket around them.

import Foundation

public enum RloginProtocol {
    public static let defaultPort = 513

    /// The initial handshake: a leading NUL, then three NUL-terminated strings —
    /// the local user, the remote user, and "termtype/speed".
    public static func connectString(localUser: String, remoteUser: String,
                                     termType: String = "xterm-256color",
                                     speed: Int = 38400) -> [UInt8] {
        var bytes: [UInt8] = [0x00]
        bytes.append(contentsOf: Array(localUser.utf8)); bytes.append(0x00)
        bytes.append(contentsOf: Array(remoteUser.utf8)); bytes.append(0x00)
        bytes.append(contentsOf: Array("\(termType)/\(speed)".utf8)); bytes.append(0x00)
        return bytes
    }

    /// The window-size control message, sent inline in the client→server stream:
    /// the magic `0xFF 0xFF 's' 's'` then rows, cols, x-pixels, y-pixels as
    /// big-endian uint16s.
    public static func windowSizeMessage(cols: Int, rows: Int,
                                         xPixels: Int = 0, yPixels: Int = 0) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xFF, 0x73, 0x73]      // 's' 's'
        for value in [rows, cols, xPixels, yPixels] {
            let v = UInt16(clamping: value)
            bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF))
        }
        return bytes
    }

    /// The result of inspecting the server's first byte.
    public enum Handshake: Equatable {
        /// Server accepted; `data` is any terminal output already in the packet.
        case accepted(data: [UInt8])
        /// Server refused; `message` is the human text it sent after the byte.
        case rejected(message: String)
    }

    /// The server's reply begins with one status byte: 0x00 means success, and
    /// anything after it is terminal output; any other first byte is a failure
    /// whose reason is the rest of the packet.
    public static func interpretReply(_ bytes: [UInt8]) -> Handshake {
        guard let first = bytes.first else { return .accepted(data: []) }
        if first == 0x00 {
            return .accepted(data: Array(bytes.dropFirst()))
        }
        let message = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .rejected(message: message.isEmpty ? "rlogin connection refused" : message)
    }
}

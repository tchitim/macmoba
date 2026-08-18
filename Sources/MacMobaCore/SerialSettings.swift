// The parameters of a serial line, and the ports available to open.
//
// "9600 8N1" is the default nobody has to think about: 9600 baud, 8 data bits,
// no parity, 1 stop bit. The format string is the compact notation printed on
// every device's manual. Parsing and enumeration are pure, so they can be
// tested without a cable.

import Foundation

public struct SerialSettings: Equatable, Sendable {
    public enum Parity: String, Sendable, CaseIterable {
        case none = "N"
        case even = "E"
        case odd = "O"
    }

    public var baud: Int
    public var dataBits: Int
    public var parity: Parity
    public var stopBits: Int

    /// Build from a baud rate and a "8N1"-style format. An unparseable or nil
    /// format falls back to 8N1 rather than failing.
    public init(baud: Int, format: String?) {
        self.baud = baud
        let parsed = SerialSettings.parseFormat(format ?? "")
        self.dataBits = parsed.dataBits
        self.parity = parsed.parity
        self.stopBits = parsed.stopBits
    }

    public init(baud: Int = 9600, dataBits: Int = 8,
                parity: Parity = .none, stopBits: Int = 1) {
        self.baud = baud
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
    }

    public var formatString: String { "\(dataBits)\(parity.rawValue)\(stopBits)" }

    /// The common baud rates offered in the editor.
    public static let commonBauds = [9600, 19200, 38400, 57600, 115200, 230400]

    /// Parse "8N1", "7E1", "8n2" (case-insensitive). Anything off falls back to
    /// the matching default field, so a partly-typed value never blocks a save.
    static func parseFormat(_ text: String) -> (dataBits: Int, parity: Parity, stopBits: Int) {
        let chars = Array(text.uppercased())
        var dataBits = 8, stopBits = 1
        var parity = Parity.none
        if chars.count >= 1, let d = chars[0].wholeNumberValue, (5...8).contains(d) {
            dataBits = d
        }
        if chars.count >= 2, let p = Parity(rawValue: String(chars[1])) {
            parity = p
        }
        if chars.count >= 3, let s = chars[2].wholeNumberValue, (1...2).contains(s) {
            stopBits = s
        }
        return (dataBits, parity, stopBits)
    }
}

public enum SerialPort {
    /// The serial devices on this Mac. The call-out (`/dev/cu.*`) nodes are the
    /// ones to open for outgoing use — the `/dev/tty.*` twins block on carrier
    /// detect — so those come first, with the ttys after for completeness.
    public static func available() -> [String] {
        let dev = "/dev/"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dev)) ?? []
        let cu = names.filter { $0.hasPrefix("cu.") }.sorted().map { dev + $0 }
        let tty = names.filter { $0.hasPrefix("tty.") }.sorted().map { dev + $0 }
        return cu + tty
    }
}

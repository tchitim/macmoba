// Telnet (RFC 854) option negotiation, as a pure state machine.
//
// Kept free of any socket so it can be tested directly: feed it the bytes that
// arrived, get back what to show in the terminal and what to send in reply.
// Telnet's negotiation is small but full of traps — an unescaped 0xFF, or a
// reply to a reply, and a session either corrupts its output or loops forever.

import Foundation

public enum TelnetCommand {
    public static let se: UInt8 = 240      // end of subnegotiation
    public static let nop: UInt8 = 241
    public static let dataMark: UInt8 = 242
    public static let brk: UInt8 = 243
    public static let ip: UInt8 = 244      // interrupt process
    public static let ao: UInt8 = 245
    public static let ayt: UInt8 = 246
    public static let ec: UInt8 = 247
    public static let el: UInt8 = 248
    public static let ga: UInt8 = 249      // go ahead
    public static let sb: UInt8 = 250      // begin subnegotiation
    public static let will: UInt8 = 251
    public static let wont: UInt8 = 252
    public static let doCommand: UInt8 = 253
    public static let dont: UInt8 = 254
    public static let iac: UInt8 = 255     // interpret as command
}

public enum TelnetOption {
    public static let binary: UInt8 = 0
    public static let echo: UInt8 = 1
    public static let suppressGoAhead: UInt8 = 3
    public static let status: UInt8 = 5
    public static let terminalType: UInt8 = 24
    public static let windowSize: UInt8 = 31   // NAWS
}

public struct TelnetNegotiator {
    public struct Output: Equatable {
        /// Payload for the terminal, with all commands stripped and IAC IAC
        /// collapsed back to a single 0xFF.
        public var terminalData: [UInt8]
        /// Bytes to write back to the server.
        public var reply: [UInt8]

        public init(terminalData: [UInt8] = [], reply: [UInt8] = []) {
            self.terminalData = terminalData
            self.reply = reply
        }
    }

    private enum State {
        case data
        case command                 // saw IAC
        case negotiating(UInt8)      // saw IAC WILL/WONT/DO/DONT
        case subnegotiating          // inside IAC SB ... IAC SE
        case subnegotiatingIAC       // saw IAC while inside a subnegotiation
    }

    private var state: State = .data
    private var subnegotiation: [UInt8] = []

    /// What we answer a TERMINAL-TYPE request with.
    public let terminalType: String
    /// Last size reported, so NAWS can be re-sent when the option is enabled
    /// after the terminal already knows its size.
    private var cols: Int
    private var rows: Int

    /// Options we have already agreed to, so repeated negotiation from the
    /// server does not produce a reply each time. Two implementations that both
    /// answer every message will otherwise ping-pong forever — RFC 854 is
    /// explicit that you only respond when the state actually changes.
    private var enabledLocally: Set<UInt8> = []
    private var refusedLocally: Set<UInt8> = []
    private var enabledRemotely: Set<UInt8> = []
    private var refusedRemotely: Set<UInt8> = []

    /// Options we are willing to perform ourselves.
    private static let supportedLocal: Set<UInt8> = [
        TelnetOption.terminalType, TelnetOption.windowSize, TelnetOption.suppressGoAhead,
    ]
    /// Options we are happy for the server to perform.
    private static let supportedRemote: Set<UInt8> = [
        TelnetOption.echo, TelnetOption.suppressGoAhead,
    ]

    public init(terminalType: String = "xterm-256color", cols: Int = 80, rows: Int = 24) {
        self.terminalType = terminalType
        self.cols = cols
        self.rows = rows
    }

    /// True once the server has told us it will echo. The terminal must not
    /// also echo locally, or every character appears twice.
    public private(set) var serverEchoes = false

    public mutating func receive(_ bytes: [UInt8]) -> Output {
        var output = Output()
        for byte in bytes {
            switch state {
            case .data:
                if byte == TelnetCommand.iac {
                    state = .command
                } else {
                    output.terminalData.append(byte)
                }

            case .command:
                switch byte {
                case TelnetCommand.iac:
                    // Escaped 0xFF: real data, not a command.
                    output.terminalData.append(TelnetCommand.iac)
                    state = .data
                case TelnetCommand.will, TelnetCommand.wont,
                     TelnetCommand.doCommand, TelnetCommand.dont:
                    state = .negotiating(byte)
                case TelnetCommand.sb:
                    subnegotiation.removeAll()
                    state = .subnegotiating
                default:
                    // NOP, GA, and the rest carry nothing we act on.
                    state = .data
                }

            case .negotiating(let command):
                output.reply += respond(to: command, option: byte)
                state = .data

            case .subnegotiating:
                if byte == TelnetCommand.iac {
                    state = .subnegotiatingIAC
                } else {
                    subnegotiation.append(byte)
                }

            case .subnegotiatingIAC:
                if byte == TelnetCommand.se {
                    output.reply += handleSubnegotiation(subnegotiation)
                    subnegotiation.removeAll()
                    state = .data
                } else if byte == TelnetCommand.iac {
                    subnegotiation.append(TelnetCommand.iac)
                    state = .subnegotiating
                } else {
                    // Some other command spliced into a subnegotiation; ignore
                    // it and keep collecting rather than losing the block.
                    state = .subnegotiating
                }
            }
        }
        return output
    }

    private mutating func respond(to command: UInt8, option: UInt8) -> [UInt8] {
        switch command {
        // The server asks us to enable something.
        case TelnetCommand.doCommand:
            if Self.supportedLocal.contains(option) {
                guard !enabledLocally.contains(option) else { return [] }
                enabledLocally.insert(option)
                refusedLocally.remove(option)
                var reply = [TelnetCommand.iac, TelnetCommand.will, option]
                // A server that asks for NAWS wants the size immediately;
                // waiting for the next resize leaves it guessing at 80x24.
                if option == TelnetOption.windowSize { reply += windowSizeSubnegotiation() }
                return reply
            }
            guard !refusedLocally.contains(option) else { return [] }
            refusedLocally.insert(option)
            return [TelnetCommand.iac, TelnetCommand.wont, option]

        case TelnetCommand.dont:
            guard enabledLocally.contains(option) || !refusedLocally.contains(option) else {
                return []
            }
            enabledLocally.remove(option)
            refusedLocally.insert(option)
            return [TelnetCommand.iac, TelnetCommand.wont, option]

        // The server offers to enable something.
        case TelnetCommand.will:
            if Self.supportedRemote.contains(option) {
                guard !enabledRemotely.contains(option) else { return [] }
                enabledRemotely.insert(option)
                refusedRemotely.remove(option)
                if option == TelnetOption.echo { serverEchoes = true }
                return [TelnetCommand.iac, TelnetCommand.doCommand, option]
            }
            guard !refusedRemotely.contains(option) else { return [] }
            refusedRemotely.insert(option)
            return [TelnetCommand.iac, TelnetCommand.dont, option]

        case TelnetCommand.wont:
            if option == TelnetOption.echo { serverEchoes = false }
            guard enabledRemotely.contains(option) || !refusedRemotely.contains(option) else {
                return []
            }
            enabledRemotely.remove(option)
            refusedRemotely.insert(option)
            return [TelnetCommand.iac, TelnetCommand.dont, option]

        default:
            return []
        }
    }

    private func handleSubnegotiation(_ payload: [UInt8]) -> [UInt8] {
        guard let option = payload.first else { return [] }
        switch option {
        case TelnetOption.terminalType:
            // IAC SB TERMINAL-TYPE SEND IAC SE  →  IAC SB TERMINAL-TYPE IS <name> IAC SE
            guard payload.count >= 2, payload[1] == 1 else { return [] }
            var reply: [UInt8] = [TelnetCommand.iac, TelnetCommand.sb,
                                  TelnetOption.terminalType, 0]
            reply += Array(terminalType.utf8)
            reply += [TelnetCommand.iac, TelnetCommand.se]
            return reply
        default:
            return []
        }
    }

    /// NAWS payload for the current size. Empty unless the server asked for it.
    public mutating func windowSizeChanged(cols: Int, rows: Int) -> [UInt8] {
        self.cols = cols
        self.rows = rows
        guard enabledLocally.contains(TelnetOption.windowSize) else { return [] }
        return windowSizeSubnegotiation()
    }

    private func windowSizeSubnegotiation() -> [UInt8] {
        // Width and height are 16-bit big-endian, and each byte is subject to
        // IAC escaping — a terminal 255 columns wide would otherwise end the
        // subnegotiation early.
        let width = UInt16(clamping: cols)
        let height = UInt16(clamping: rows)
        var payload: [UInt8] = [TelnetCommand.iac, TelnetCommand.sb, TelnetOption.windowSize]
        payload += Self.escape([UInt8(width >> 8), UInt8(width & 0xFF),
                                UInt8(height >> 8), UInt8(height & 0xFF)])
        payload += [TelnetCommand.iac, TelnetCommand.se]
        return payload
    }

    /// Doubles any 0xFF so it survives as data rather than being read as IAC.
    public static func escape(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(TelnetCommand.iac) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        for byte in bytes {
            out.append(byte)
            if byte == TelnetCommand.iac { out.append(TelnetCommand.iac) }
        }
        return out
    }

    /// Prepares typed input for the wire. As well as escaping IAC, a bare CR
    /// has to be followed by NUL: RFC 854 reserves CR LF for "new line", so a
    /// lone CR is ambiguous and some servers act on it and some ignore it.
    public static func encodeInput(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            out.append(byte)
            if byte == TelnetCommand.iac {
                out.append(TelnetCommand.iac)
            } else if byte == 0x0D {
                let next = bytes.index(after: index)
                let following = next < bytes.endIndex ? bytes[next] : nil
                if following != 0x0A && following != 0x00 { out.append(0x00) }
            }
            index = bytes.index(after: index)
        }
        return out
    }
}

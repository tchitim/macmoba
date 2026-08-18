// "Which pane needs me?" — the question cmux exists to answer, made generic.
//
// Two signals cover almost every remote program, agents included:
//
//   * BEL (0x07): the program rang the bell. Claude Code does this when it
//     finishes or needs an answer; so do builds, pagers and IRC clients.
//   * Output after silence: a pane quiet for half a minute suddenly printing
//     again means the long-running thing progressed or finished.
//
// This is a pure state machine — bytes and timestamps in, triggers out — so
// the rules are unit-testable. The one subtlety lives here too: BEL is ALSO
// the terminator of OSC strings (every title change ends in 0x07), so a bell
// inside an escape string sequence must not count as attention.

import Foundation

public struct AttentionDetector: Sendable {
    public enum Trigger: Equatable, Sendable {
        /// The program rang the terminal bell.
        case bell
        /// Output arrived after at least `silence` seconds of quiet.
        case resumedAfterSilence(TimeInterval)
    }

    /// How long a pane must be quiet before new output counts as "resumed".
    public let silenceThreshold: TimeInterval

    // Minimal escape-sequence tracking, just enough to know when a BEL is a
    // string terminator rather than a bell.
    private enum ParseState { case normal, escape, stringSequence, csi }
    private var parseState: ParseState = .normal
    private var lastOutputAt: TimeInterval?

    public init(silenceThreshold: TimeInterval = 30) {
        self.silenceThreshold = silenceThreshold
    }

    /// Feed a received chunk with its arrival time (any monotonic clock).
    /// Returns the strongest trigger this chunk produced, or nil. A bell
    /// outranks a resume — it is an explicit request for attention.
    public mutating func observe<S: Sequence>(_ bytes: S, at time: TimeInterval) -> Trigger?
        where S.Element == UInt8 {
        var sawBell = false
        for byte in bytes {
            switch parseState {
            case .normal:
                if byte == 0x07 { sawBell = true }
                else if byte == 0x1B { parseState = .escape }
            case .escape:
                switch byte {
                // OSC / DCS / APC / PM open a string sequence: BEL inside is a
                // terminator (title changes end this way), never a bell.
                case UInt8(ascii: "]"), UInt8(ascii: "P"),
                     UInt8(ascii: "_"), UInt8(ascii: "^"):
                    parseState = .stringSequence
                case UInt8(ascii: "["):
                    parseState = .csi
                default:
                    parseState = .normal
                }
            case .stringSequence:
                // Ends at BEL or at ST (ESC \). The ESC of an ST routes through
                // .escape, whose default arm lands back in .normal — good enough.
                if byte == 0x07 { parseState = .normal }
                else if byte == 0x1B { parseState = .escape }
            case .csi:
                // A CSI ends at its final byte (0x40–0x7E); it cannot contain BEL.
                if (0x40...0x7E).contains(byte) { parseState = .normal }
            }
        }

        let previous = lastOutputAt
        lastOutputAt = time

        if sawBell { return .bell }
        // The first output ever is a connection banner, not a resume.
        if let previous, time - previous >= silenceThreshold {
            return .resumedAfterSilence(time - previous)
        }
        return nil
    }
}

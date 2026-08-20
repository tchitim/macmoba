// ZMODEM primitives — the byte-level pieces of the rz/sz file-transfer protocol
// that runs inside a terminal session. Kept separate from the receiver state
// machine because every one of these is a pure function with a right answer:
// the CRCs have published test vectors, and the escaping and framing round-trip.
//
// Reference: Chuck Forsberg's ZMODEM spec. Only what a receiver (the "rz" side,
// getting a file a remote `sz` is sending) needs is implemented, plus the
// framing a sender would share.

import Foundation

public enum ZModem {
    // Control bytes.
    public static let ZPAD: UInt8 = 0x2A   // '*'
    public static let ZDLE: UInt8 = 0x18   // ^X
    public static let ZDLEE: UInt8 = 0x58  // ZDLE ^ 0x40
    public static let ZBIN: UInt8 = 0x41   // 'A' — binary frame, CRC-16
    public static let ZHEX: UInt8 = 0x42   // 'B' — hex frame
    public static let ZBIN32: UInt8 = 0x43 // 'C' — binary frame, CRC-32

    // Frame types.
    public enum FrameType: UInt8, Equatable, Sendable {
        case ZRQINIT = 0, ZRINIT = 1, ZSINIT = 2, ZACK = 3, ZFILE = 4, ZSKIP = 5
        case ZNAK = 6, ZABORT = 7, ZFIN = 8, ZRPOS = 9, ZDATA = 10, ZEOF = 11
        case ZFERR = 12, ZCRC = 13, ZCHALLENGE = 14, ZCOMPL = 15, ZCAN = 16
        case ZFREECNT = 17, ZCOMMAND = 18, ZSTDERR = 19
    }

    // Subpacket terminators (follow a ZDLE inside a data subpacket).
    public static let ZCRCE: UInt8 = 0x68  // 'h' end, header follows
    public static let ZCRCG: UInt8 = 0x69  // 'i' continue, no ack
    public static let ZCRCQ: UInt8 = 0x6A  // 'j' continue, ack expected
    public static let ZCRCW: UInt8 = 0x6B  // 'k' end, ack expected

    // Escaped-control decode helpers.
    static let ZRUB0: UInt8 = 0x6C         // -> 0x7F
    static let ZRUB1: UInt8 = 0x6D         // -> 0xFF

    // MARK: - CRC

    /// CRC-16/XMODEM (CCITT, poly 0x1021, MSB-first, init 0) — ZMODEM's 16-bit
    /// CRC over header and subpacket data.
    public static func crc16(_ bytes: [UInt8], seed: UInt16 = 0) -> UInt16 {
        var crc = seed
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
        }
        return crc
    }

    /// CRC-32 (reflected, poly 0xEDB88320) as ZMODEM stores it: init 0xFFFFFFFF
    /// and the final value complemented.
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - ZDLE escaping

    /// Which bytes a sender escapes: ZDLE itself and the flow-control-sensitive
    /// controls, in both their 7-bit and 8-bit (|0x80) forms.
    static func mustEscape(_ b: UInt8) -> Bool {
        switch b & 0x7F {
        case 0x10, 0x11, 0x13, ZDLE & 0x7F: return true      // DLE, XON, XOFF, ZDLE
        default: return false
        }
    }

    /// Escape a run of data bytes for a subpacket or binary header.
    public static func escape(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for b in data {
            if b == ZDLE {
                out.append(ZDLE); out.append(ZDLEE)
            } else if mustEscape(b) {
                out.append(ZDLE); out.append(b ^ 0x40)
            } else {
                out.append(b)
            }
        }
        return out
    }

    /// The plain byte a ZDLE-escaped byte stands for.
    static func unescapeByte(_ b: UInt8) -> UInt8 {
        switch b {
        case ZRUB0: return 0x7F
        case ZRUB1: return 0xFF
        default: return b ^ 0x40
        }
    }

    // MARK: - Header encoding

    /// A hex header: `* * ZDLE 'B'` then type+4 bytes as hex, the CRC-16 as hex,
    /// then CR LF (and XON). This is what control frames (ZRINIT, ZRPOS, ZACK,
    /// ZFIN…) are sent as.
    public static func hexHeader(_ type: FrameType, _ p0: UInt8 = 0, _ p1: UInt8 = 0,
                                 _ p2: UInt8 = 0, _ p3: UInt8 = 0) -> [UInt8] {
        let core: [UInt8] = [type.rawValue, p0, p1, p2, p3]
        let crc = crc16(core)
        var out: [UInt8] = [ZPAD, ZPAD, ZDLE, ZHEX]
        for b in core { out.append(contentsOf: hex(b)) }
        out.append(contentsOf: hex(UInt8(crc >> 8)))
        out.append(contentsOf: hex(UInt8(crc & 0xFF)))
        out.append(contentsOf: [0x0D, 0x0A])       // CR LF
        if type != .ZACK && type != .ZFIN {         // sender adds XON except here
            out.append(0x11)
        }
        return out
    }

    /// A binary CRC-16 header: `* ZDLE 'A'` then type+4 and CRC-16, all ZDLE-
    /// escaped. Used to introduce ZDATA/ZFILE where a data subpacket follows.
    public static func binaryHeader(_ type: FrameType, _ p0: UInt8 = 0, _ p1: UInt8 = 0,
                                    _ p2: UInt8 = 0, _ p3: UInt8 = 0) -> [UInt8] {
        let core: [UInt8] = [type.rawValue, p0, p1, p2, p3]
        let crc = crc16(core)
        var payload = core
        payload.append(UInt8(crc >> 8)); payload.append(UInt8(crc & 0xFF))
        return [ZPAD, ZDLE, ZBIN] + escape(payload)
    }

    /// The little-endian 32-bit position/flags for ZRPOS/ZEOF/ZDATA.
    public static func positionBytes(_ value: UInt32) -> (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF))
    }

    private static func hex(_ b: UInt8) -> [UInt8] {
        let digits = Array("0123456789abcdef".utf8)
        return [digits[Int(b >> 4)], digits[Int(b & 0x0F)]]
    }

    /// Encode a data subpacket: escaped data, then `ZDLE <frameEnd>`, then the
    /// CRC (over data + frameEnd), escaped. CRC-16 unless `crc32` is set.
    public static func dataSubpacket(_ data: [UInt8], frameEnd: UInt8, crc32: Bool = false) -> [UInt8] {
        var out = escape(data)
        out.append(ZDLE); out.append(frameEnd)
        let covered = data + [frameEnd]
        if crc32 {
            let c = self.crc32(covered)
            out += escape([UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF),
                           UInt8((c >> 16) & 0xFF), UInt8((c >> 24) & 0xFF)])
        } else {
            let c = crc16(covered)
            out += escape([UInt8(c >> 8), UInt8(c & 0xFF)])
        }
        return out
    }

    /// The next hex header in `bytes` (the only kind a sender receives from a
    /// remote `rz`: ZRINIT, ZRPOS, ZACK, ZFIN…). Returns its type, position, the
    /// frame's start (backed up over `*` pads, so a caller can drop the preamble)
    /// and the index just past it. Nil if none is fully present yet.
    public static func nextHexHeader(in bytes: [UInt8])
        -> (type: FrameType, position: UInt32, start: Int, end: Int)? {
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == ZDLE && bytes[i + 1] == ZHEX {
                let hexStart = i + 2
                guard bytes.count >= hexStart + 14 else { return nil }   // incomplete
                var raw: [UInt8] = []
                var j = hexStart
                var ok = true
                while raw.count < 7 {
                    guard let hi = hexVal(bytes[j]), let lo = hexVal(bytes[j + 1]) else { ok = false; break }
                    raw.append(hi << 4 | lo); j += 2
                }
                if ok, let type = FrameType(rawValue: raw[0]) {
                    var end = j
                    while end < bytes.count, bytes[end] == 0x0D || bytes[end] == 0x0A || bytes[end] == 0x11 {
                        end += 1
                    }
                    let pos = UInt32(raw[1]) | UInt32(raw[2]) << 8 | UInt32(raw[3]) << 16 | UInt32(raw[4]) << 24
                    var start = i
                    while start > 0 && bytes[start - 1] == ZPAD { start -= 1 }
                    return (type, pos, start, end)
                }
            }
            i += 1
        }
        return nil
    }

    static func hexVal(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    /// Where a ZMODEM transfer announces itself in a terminal stream (a ZRQINIT
    /// hex header, `ZDLE 'B' '0' '0'`), or nil. A pane uses this to flip into
    /// receive mode. The index backs up over the leading `*` pad bytes so the
    /// receiver is handed the whole header.
    public static func receiveTriggerIndex(in bytes: [UInt8]) -> Int? {
        let marker: [UInt8] = [ZDLE, ZHEX, 0x30, 0x30]   // ZDLE 'B' '0' '0'
        guard var idx = firstIndex(of: marker, in: bytes) else { return nil }
        while idx > 0 && bytes[idx - 1] == ZPAD { idx -= 1 }
        return idx
    }

    /// True when the stream carries a ZRINIT — a receiver on the other end
    /// announcing that it is waiting, which is what `rz` sends over and over
    /// while it sits there.
    ///
    /// Worth telling apart from a download's ZRQINIT: a send normally starts by
    /// typing `rz` on the remote, and typing it at an `rz` that is ALREADY
    /// running feeds the word "rz" into the transfer as data and wedges both
    /// ends. Knowing one is waiting means not typing it.
    public static func receiverIsWaiting(in bytes: [UInt8]) -> Bool {
        let marker: [UInt8] = [ZDLE, ZHEX, 0x30, 0x31]   // ZDLE 'B' '0' '1'
        return firstIndex(of: marker, in: bytes) != nil
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<start + needle.count]) == needle { return start }
        }
        return nil
    }
}

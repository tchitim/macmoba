// The receiving half of ZMODEM — the "rz" side, driven by bytes a remote `sz`
// sends. Fed the inbound stream, it returns the bytes to send back and, when a
// file finishes, hands over its name and contents. This is what lets "run `sz
// file` on the server" drop the file onto the Mac.
//
// It is a streaming parser: feed() consumes whole frames and subpackets and
// buffers any partial tail for next time, so it works no matter how the bytes
// are chunked. CRCs are checked; a bad one asks the sender to resend from the
// last good position.

import Foundation

public final class ZModemReceiver {
    public struct ReceivedFile: Equatable, Sendable {
        public let name: String
        public let data: Data
    }

    public private(set) var files: [ReceivedFile] = []
    public private(set) var isComplete = false

    private var buffer: [UInt8] = []
    private var currentName: String?
    private var currentData: [UInt8] = []
    private var expectedSize: Int?
    private var use32 = false
    /// True between a ZDATA header and the subpacket that ends its frame. While
    /// set, the front of the buffer is raw subpacket data, not a new frame.
    private var inDataFrame = false

    public init() {}

    /// Advertised capabilities: full duplex + overlapped I/O, CRC-16 (we do not
    /// set CANFC32, which keeps subpackets on the simpler 16-bit CRC).
    private static let rinitFlags: UInt8 = 0x03   // CANFDX | CANOVIO

    /// Feed inbound bytes; returns bytes to transmit back to the sender.
    @discardableResult
    public func feed(_ incoming: [UInt8]) -> [UInt8] {
        buffer.append(contentsOf: incoming)
        var out: [UInt8] = []
        var progressed = true
        while progressed && !isComplete {
            progressed = false
            if let (response, consumed) = step() {
                out += response
                buffer.removeFirst(consumed)
                progressed = true
            }
        }
        return out
    }

    /// Parse one frame or subpacket from the front of the buffer, if a whole one
    /// is present. Returns the bytes to send and how many input bytes it used.
    private func step() -> (response: [UInt8], consumed: Int)? {
        // Inside a ZDATA frame, the buffer front is raw subpacket data. Consume
        // exactly one subpacket at a time, so an incomplete frame never re-reads
        // subpackets already committed.
        if inDataFrame { return stepDataSubpacket() }

        guard let dleIndex = findFrameStart() else { return nil }
        // Drop anything before the frame intro (banners like "rz\r", noise).
        if dleIndex > 0 { return ([], dleIndex) }

        guard buffer.count >= 2 else { return nil }
        switch buffer[1] {
        case ZModem.ZHEX: return parseHexHeader()
        case ZModem.ZBIN: use32 = false; return parseBinaryHeader(crc32: false)
        case ZModem.ZBIN32: use32 = true; return parseBinaryHeader(crc32: true)
        default:
            // Unknown format byte after ZDLE — skip the ZDLE and resync.
            return ([], 1)
        }
    }

    /// Consume one data subpacket from the front of the buffer (called only while
    /// `inDataFrame`). Each is committed as it is read, so a partial frame does
    /// not double-count.
    private func stepDataSubpacket() -> (response: [UInt8], consumed: Int)? {
        guard let (data, frameEnd, consumed, crcValid) = readSubpacket(from: 0) else { return nil }
        guard crcValid else {
            inDataFrame = false
            let (p0, p1, p2, p3) = ZModem.positionBytes(UInt32(currentData.count))
            return (ZModem.hexHeader(.ZRPOS, p0, p1, p2, p3), consumed)
        }
        currentData.append(contentsOf: data)
        switch frameEnd {
        case ZModem.ZCRCG:
            return ([], consumed)                         // more subpackets follow
        case ZModem.ZCRCQ:
            return (ZModem.hexHeader(.ZACK), consumed)
        case ZModem.ZCRCE:
            inDataFrame = false
            return ([], consumed)
        case ZModem.ZCRCW:
            inDataFrame = false
            return (ZModem.hexHeader(.ZACK), consumed)
        default:
            inDataFrame = false
            return ([], consumed)
        }
    }

    /// Index of the next `ZDLE <format>` frame intro in the buffer.
    private func findFrameStart() -> Int? {
        var i = 0
        while i + 1 < buffer.count {
            if buffer[i] == ZModem.ZDLE {
                let f = buffer[i + 1]
                if f == ZModem.ZHEX || f == ZModem.ZBIN || f == ZModem.ZBIN32 { return i }
            }
            i += 1
        }
        // A lone trailing ZDLE might be the start of an intro we have not fully
        // received; keep it. Otherwise nothing usable yet.
        return (buffer.last == ZModem.ZDLE) ? nil : nil
    }

    // MARK: - headers

    private func parseHexHeader() -> (response: [UInt8], consumed: Int)? {
        // ZDLE 'B' then 14 hex digits (7 bytes) then CR LF (maybe XON).
        let hexStart = 2
        guard buffer.count >= hexStart + 14 else { return nil }
        var raw: [UInt8] = []
        var i = hexStart
        while raw.count < 7 {
            guard let hi = hexVal(buffer[i]), let lo = hexVal(buffer[i + 1]) else { return ([], 1) }
            raw.append(hi << 4 | lo); i += 2
        }
        // Skip trailing CR LF and optional XON.
        var end = i
        while end < buffer.count, buffer[end] == 0x0D || buffer[end] == 0x0A || buffer[end] == 0x11 {
            end += 1
        }
        guard let type = ZModem.FrameType(rawValue: raw[0]) else { return ([], end) }
        let pos = UInt32(raw[1]) | UInt32(raw[2]) << 8 | UInt32(raw[3]) << 16 | UInt32(raw[4]) << 24
        return (handle(type: type, position: pos), end)
    }

    private func parseBinaryHeader(crc32: Bool) -> (response: [UInt8], consumed: Int)? {
        // ZDLE 'A'/'C' then 5 core + CRC (2 or 4), all ZDLE-escaped. The `2`
        // skips the ZDLE and the format byte; headerEnd is the absolute index
        // where the header stops and any subpacket begins.
        let need = 5 + (crc32 ? 4 : 2)
        guard let (bytes, headerConsumed) = readEscaped(count: need, from: 2) else { return nil }
        let headerEnd = 2 + headerConsumed
        guard let type = ZModem.FrameType(rawValue: bytes[0]) else { return ([], headerEnd) }
        let pos = UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24
        // A binary header introduces a data subpacket for ZFILE and ZDATA.
        switch type {
        case .ZFILE:
            guard let (data, _, subConsumed, crcValid) = readSubpacket(from: headerEnd) else { return nil }
            if crcValid { parseFileHeader(data) }
            return (ZModem.hexHeader(.ZRPOS, 0, 0, 0, 0), headerEnd + subConsumed)
        case .ZDATA:
            // The subpackets that follow are read one at a time by step().
            inDataFrame = true
            return ([], headerEnd)
        default:
            return (handle(type: type, position: pos), headerEnd)
        }
    }

    // MARK: - frame handling

    private func handle(type: ZModem.FrameType, position: UInt32) -> [UInt8] {
        switch type {
        case .ZRQINIT:
            return ZModem.hexHeader(.ZRINIT, 0, 0, 0, Self.rinitFlags)
        case .ZEOF:
            finishFile()
            return ZModem.hexHeader(.ZRINIT, 0, 0, 0, Self.rinitFlags)
        case .ZFIN:
            isComplete = true
            return ZModem.hexHeader(.ZFIN)          // then the sender sends "OO"
        default:
            return []
        }
    }

    /// A ZFILE subpacket is "name\0size mtime mode ... \0".
    private func parseFileHeader(_ data: [UInt8]) {
        guard let nul = data.firstIndex(of: 0) else { return }
        currentName = String(decoding: data[0..<nul], as: UTF8.self)
        currentData = []
        let rest = String(decoding: data[(nul + 1)...], as: UTF8.self)
        // First field of the rest is the size in bytes.
        if let sizeField = rest.split(whereSeparator: { $0 == " " || $0 == "\0" }).first {
            expectedSize = Int(sizeField)
        }
    }

    private func finishFile() {
        guard let name = currentName else { return }
        var data = currentData
        if let size = expectedSize, size < data.count { data = Array(data.prefix(size)) }
        files.append(ReceivedFile(name: name, data: Data(data)))
        currentName = nil
        currentData = []
        expectedSize = nil
    }

    // MARK: - low-level readers

    /// Read `count` plain bytes starting at `start`, undoing ZDLE escaping.
    /// Returns the bytes and how many buffer bytes were consumed, or nil if the
    /// buffer does not yet hold that many.
    private func readEscaped(count: Int, from start: Int) -> (bytes: [UInt8], consumed: Int)? {
        var out: [UInt8] = []
        var i = start
        while out.count < count {
            guard i < buffer.count else { return nil }
            if buffer[i] == ZModem.ZDLE {
                guard i + 1 < buffer.count else { return nil }
                out.append(ZModem.unescapeByte(buffer[i + 1])); i += 2
            } else {
                out.append(buffer[i]); i += 1
            }
        }
        return (out, i - start)
    }

    /// Read one data subpacket: escaped data bytes up to `ZDLE <frameend>`, then
    /// the CRC. Verifies the CRC. Returns data, the frame-end byte, and bytes
    /// consumed from `start`; nil if the subpacket is not fully buffered.
    private func readSubpacket(from start: Int)
        -> (data: [UInt8], frameEnd: UInt8, consumed: Int, crcValid: Bool)? {
        var data: [UInt8] = []
        var i = start
        while i < buffer.count {
            let b = buffer[i]
            if b == ZModem.ZDLE {
                guard i + 1 < buffer.count else { return nil }
                let n = buffer[i + 1]
                if n >= ZModem.ZCRCE && n <= ZModem.ZCRCW {
                    // Frame end; the CRC follows (also escaped).
                    let crcLen = use32 ? 4 : 2
                    guard let (crcBytes, crcConsumed) = readEscaped(count: crcLen, from: i + 2) else {
                        return nil
                    }
                    let consumed = (i + 2 - start) + crcConsumed
                    let valid = crcOK(data: data, frameEnd: n, crcBytes: crcBytes)
                    return (data, n, consumed, valid)
                }
                data.append(ZModem.unescapeByte(n)); i += 2
            } else {
                data.append(b); i += 1
            }
        }
        return nil
    }

    private func crcOK(data: [UInt8], frameEnd: UInt8, crcBytes: [UInt8]) -> Bool {
        let covered = data + [frameEnd]
        if use32 {
            let expected = UInt32(crcBytes[0]) | UInt32(crcBytes[1]) << 8
                | UInt32(crcBytes[2]) << 16 | UInt32(crcBytes[3]) << 24
            return ZModem.crc32(covered) == expected
        } else {
            let expected = UInt16(crcBytes[0]) << 8 | UInt16(crcBytes[1])
            return ZModem.crc16(covered) == expected
        }
    }

    private func hexVal(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

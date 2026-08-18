// The sending half of ZMODEM — the "sz" side, pushing a file to a remote `rz`.
// Fed the receiver's replies (all hex headers), it returns the bytes to send.
//
// The dance: the receiver announces itself with ZRINIT; we answer with a ZFILE
// naming the file; it replies ZRPOS asking for data from an offset; we stream
// ZDATA subpackets and finish with ZEOF; it sends ZRINIT again and we close with
// ZFIN, to which it replies ZFIN and we sign off with "OO". Data uses CRC-16 —
// simpler than CRC-32 and every rz accepts it.

import Foundation

public final class ZModemSender {
    public let name: String
    private let data: [UInt8]
    private let subpacketSize: Int

    private var buffer: [UInt8] = []
    private var sentFile = false
    private var sentEOF = false
    public private(set) var isComplete = false

    public init(name: String, data: [UInt8], subpacketSize: Int = 1024) {
        self.name = name
        self.data = data
        self.subpacketSize = subpacketSize
    }

    /// Bytes to send before any reply — a ZRQINIT to prompt a receiver that has
    /// not announced itself yet. A receiver that already sent ZRINIT ignores it.
    public func start() -> [UInt8] { ZModem.hexHeader(.ZRQINIT) }

    /// Feed the receiver's bytes; returns what to send back.
    @discardableResult
    public func feed(_ inbound: [UInt8]) -> [UInt8] {
        buffer.append(contentsOf: inbound)
        var out: [UInt8] = []
        while let header = ZModem.nextHexHeader(in: buffer) {
            buffer.removeFirst(header.end)          // drop preamble + header
            out += react(to: header.type, position: header.position)
            if isComplete { break }
        }
        // Do not let un-parsed preamble grow without bound.
        if buffer.count > 4096 { buffer = Array(buffer.suffix(1024)) }
        return out
    }

    private func react(to type: ZModem.FrameType, position: UInt32) -> [UInt8] {
        switch type {
        case .ZRINIT:
            if !sentFile {
                sentFile = true
                return fileFrame()
            } else if sentEOF {
                return ZModem.hexHeader(.ZFIN)       // all files done → close
            }
            return []
        case .ZRPOS:
            return dataFrames(from: Int(position))
        case .ZFIN:
            isComplete = true
            return Array("OO".utf8)                  // over and out
        case .ZSKIP:
            isComplete = true
            return []
        default:
            return []
        }
    }

    private func fileFrame() -> [UInt8] {
        // "name\0 length modtime(octal) mode(octal) serial files bytes\0"
        var meta = Array(name.utf8) + [0]
        meta += Array("\(data.count) 0 0 0 1 \(data.count)".utf8) + [0]
        return ZModem.binaryHeader(.ZFILE) + ZModem.dataSubpacket(meta, frameEnd: ZModem.ZCRCW)
    }

    private func dataFrames(from position: Int) -> [UInt8] {
        guard position <= data.count else { return [] }
        let (p0, p1, p2, p3) = ZModem.positionBytes(UInt32(position))
        var out = ZModem.binaryHeader(.ZDATA, p0, p1, p2, p3)

        if position == data.count {
            // Nothing left (or an empty file): a single empty end subpacket.
            out += ZModem.dataSubpacket([], frameEnd: ZModem.ZCRCE)
        } else {
            var i = position
            while i < data.count {
                let end = min(i + subpacketSize, data.count)
                let isLast = end == data.count
                out += ZModem.dataSubpacket(Array(data[i..<end]),
                                            frameEnd: isLast ? ZModem.ZCRCE : ZModem.ZCRCG)
                i = end
            }
        }
        sentEOF = true
        let (e0, e1, e2, e3) = ZModem.positionBytes(UInt32(data.count))
        out += ZModem.hexHeader(.ZEOF, e0, e1, e2, e3)
        return out
    }
}

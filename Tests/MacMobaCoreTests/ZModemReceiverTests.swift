import XCTest
@testable import MacMobaCore

final class ZModemReceiverTests: XCTestCase {

    // MARK: - synthetic stream (our encoder -> our receiver)

    func testReceivesAFileFromASynthesisedStream() {
        let contents = Array("The quick brown fox.\n".utf8)
        var stream: [UInt8] = []
        stream += ZModem.hexHeader(.ZRQINIT)
        // ZFILE header + a subpacket carrying "name\0size ...\0".
        stream += ZModem.binaryHeader(.ZFILE)
        var meta = Array("hello.txt".utf8) + [0]
        meta += Array("\(contents.count) 0 0 0 1 \(contents.count)".utf8) + [0]
        stream += subpacket(meta, frameEnd: ZModem.ZCRCW)
        // ZDATA + one subpacket ending the frame.
        stream += ZModem.binaryHeader(.ZDATA)
        stream += subpacket(contents, frameEnd: ZModem.ZCRCE)
        // ZEOF then ZFIN.
        let (p0, p1, p2, p3) = ZModem.positionBytes(UInt32(contents.count))
        stream += ZModem.hexHeader(.ZEOF, p0, p1, p2, p3)
        stream += ZModem.hexHeader(.ZFIN)

        let receiver = ZModemReceiver()
        // Feed in awkward chunks to exercise the buffering.
        for chunk in stream.chunked(into: 7) { receiver.feed(chunk) }

        XCTAssertTrue(receiver.isComplete)
        XCTAssertEqual(receiver.files.count, 1)
        XCTAssertEqual(receiver.files.first?.name, "hello.txt")
        XCTAssertEqual(receiver.files.first?.data, Data(contents))
    }

    func testRejectsCorruptSubpacket() {
        // A subpacket whose CRC does not cover the data must not be accepted.
        var stream: [UInt8] = []
        stream += ZModem.binaryHeader(.ZFILE)
        let meta = Array("x.bin".utf8) + [0] + Array("4 0 0".utf8) + [0]
        stream += subpacket(meta, frameEnd: ZModem.ZCRCW)
        stream += ZModem.binaryHeader(.ZDATA)
        stream += corruptSubpacket(Array("data".utf8))
        let (p0, p1, p2, p3) = ZModem.positionBytes(4)
        stream += ZModem.hexHeader(.ZEOF, p0, p1, p2, p3)

        let receiver = ZModemReceiver()
        receiver.feed(stream)
        // The bad data was not accepted, so the file is empty rather than "data".
        XCTAssertNotEqual(receiver.files.first?.data, Data("data".utf8))
    }

    // MARK: - ground truth: real lrzsz `sz`

    func testInteropWithRealSZ() throws {
        let szPath = ["/opt/homebrew/bin/sz", "/usr/local/bin/sz", "/usr/bin/sz"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let sz = try XCTUnwrap(szPath, "sz (lrzsz) not installed")

        // A file with content that exercises escaping (control bytes, 0x18, XON).
        let payload = Data((0..<2000).map { UInt8($0 % 251) })
        let dir = NSTemporaryDirectory() + "zm-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filePath = dir + "payload.bin"
        try payload.write(to: URL(fileURLWithPath: filePath))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sz)
        proc.arguments = [filePath]
        let toSZ = Pipe(), fromSZ = Pipe()
        proc.standardInput = toSZ
        proc.standardOutput = fromSZ
        proc.standardError = Pipe()
        try proc.run()

        let receiver = ZModemReceiver()
        let inHandle = toSZ.fileHandleForWriting
        let outHandle = fromSZ.fileHandleForReading

        // Prime the pump: our proactive ZRINIT.
        let initial = receiver.feed([])
        if !initial.isEmpty { inHandle.write(Data(initial)) }

        let deadline = Date().addingTimeInterval(15)
        while !receiver.isComplete && Date() < deadline {
            let data = outHandle.availableData        // blocks until bytes or EOF
            if data.isEmpty { break }
            let response = receiver.feed([UInt8](data))
            if !response.isEmpty { inHandle.write(Data(response)) }
        }
        proc.waitUntilExit()

        XCTAssertTrue(receiver.isComplete, "transfer did not complete")
        XCTAssertEqual(receiver.files.count, 1)
        XCTAssertEqual(receiver.files.first?.name, "payload.bin")
        if let got = receiver.files.first?.data, got != payload {
            let a = [UInt8](payload), b = [UInt8](got)
            let idx = (0..<Swift.min(a.count, b.count)).first { a[$0] != b[$0] }
            if let idx {
                XCTFail("first mismatch at \(idx): sent 0x\(String(a[idx], radix: 16)) got 0x\(String(b[idx], radix: 16)); lens \(a.count)/\(b.count)")
            }
        }
        XCTAssertEqual(receiver.files.first?.data, payload,
                       "received bytes differ from what sz sent")
    }

    // MARK: - subpacket encoders for the synthetic tests

    private func subpacket(_ data: [UInt8], frameEnd: UInt8) -> [UInt8] {
        var out = ZModem.escape(data)
        out.append(ZModem.ZDLE); out.append(frameEnd)
        let crc = ZModem.crc16(data + [frameEnd])
        out += ZModem.escape([UInt8(crc >> 8), UInt8(crc & 0xFF)])
        return out
    }

    private func corruptSubpacket(_ data: [UInt8]) -> [UInt8] {
        var out = ZModem.escape(data)
        out.append(ZModem.ZDLE); out.append(ZModem.ZCRCE)
        out += [0x00, 0x00]                           // deliberately wrong CRC
        return out
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

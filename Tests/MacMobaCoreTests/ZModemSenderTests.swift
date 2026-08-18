import XCTest
@testable import MacMobaCore

final class ZModemSenderTests: XCTestCase {

    // MARK: - sender + our own receiver, end to end in memory

    func testSenderAndReceiverAgree() {
        let payload = Array((0..<1500).map { UInt8($0 % 251) })
        let sender = ZModemSender(name: "note.bin", data: payload)
        let receiver = ZModemReceiver()

        // Drive both against each other until the sender signs off.
        var toReceiver = sender.start()
        var guardCount = 0
        while !sender.isComplete && guardCount < 100 {
            guardCount += 1
            let toSender = receiver.feed(toReceiver)
            toReceiver = sender.feed(toSender)
        }

        XCTAssertTrue(sender.isComplete)
        XCTAssertEqual(receiver.files.count, 1)
        XCTAssertEqual(receiver.files.first?.name, "note.bin")
        XCTAssertEqual(receiver.files.first?.data, Data(payload))
    }

    func testFileFrameNamesTheFile() {
        let sender = ZModemSender(name: "report.pdf", data: Array("hello".utf8))
        // The first thing after a ZRINIT is a ZFILE naming the file.
        let out = sender.feed(ZModem.hexHeader(.ZRINIT, 0, 0, 0, 0x03))
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("report.pdf"), "ZFILE should carry the name")
    }

    // MARK: - ground truth: real lrzsz `rz`

    func testInteropWithRealRZ() throws {
        let rzPath = ["/opt/homebrew/bin/rz", "/usr/local/bin/rz", "/usr/bin/rz"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let rz = try XCTUnwrap(rzPath, "rz (lrzsz) not installed")

        let payload = Data((0..<3000).map { UInt8(($0 * 7) % 251) })
        let dir = NSTemporaryDirectory() + "zms-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rz)
        proc.arguments = ["-y"]                       // overwrite if present
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)   // rz writes here
        let toRZ = Pipe(), fromRZ = Pipe()
        proc.standardInput = toRZ
        proc.standardOutput = fromRZ
        proc.standardError = Pipe()
        try proc.run()

        let sender = ZModemSender(name: "sent.bin", data: [UInt8](payload))
        let inHandle = toRZ.fileHandleForWriting
        let outHandle = fromRZ.fileHandleForReading

        let initial = sender.start()
        if !initial.isEmpty { inHandle.write(Data(initial)) }

        let deadline = Date().addingTimeInterval(15)
        while !sender.isComplete && Date() < deadline {
            let data = outHandle.availableData
            if data.isEmpty { break }
            let response = sender.feed([UInt8](data))
            if !response.isEmpty { inHandle.write(Data(response)) }
        }
        proc.waitUntilExit()

        XCTAssertTrue(sender.isComplete, "sender did not finish")
        // rz wrote the file to its working directory; it must match.
        let written = try Data(contentsOf: URL(fileURLWithPath: dir + "sent.bin"))
        XCTAssertEqual(written, payload, "rz received different bytes than we sent")
    }
}

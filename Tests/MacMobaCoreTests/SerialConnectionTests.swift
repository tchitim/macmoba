import XCTest

#if canImport(Darwin)
import Darwin
#endif

@testable import MacMobaCore

/// A serial line has no protocol above the wire, so the thing to prove is that
/// bytes go both ways with the port configured. A pseudo-terminal (posix_openpt)
/// gives a master fd and a slave device path that behaves like a serial line —
/// SerialConnection opens the slave, the test drives the master — so this runs
/// with no hardware.
final class SerialConnectionTests: XCTestCase {
    // MARK: - settings parsing

    func testDefaultFormatIs8N1() {
        let s = SerialSettings(baud: 9600, format: nil)
        XCTAssertEqual(s.dataBits, 8)
        XCTAssertEqual(s.parity, .none)
        XCTAssertEqual(s.stopBits, 1)
        XCTAssertEqual(s.formatString, "8N1")
    }

    func testParsesFormats() {
        XCTAssertEqual(SerialSettings(baud: 9600, format: "7E1").formatString, "7E1")
        XCTAssertEqual(SerialSettings(baud: 9600, format: "8O2").formatString, "8O2")
        XCTAssertEqual(SerialSettings(baud: 9600, format: "8n1").parity, SerialSettings.Parity.none)
        // Garbage falls back to the 8N1 defaults rather than failing.
        XCTAssertEqual(SerialSettings(baud: 9600, format: "zzz").formatString, "8N1")
    }

    func testAvailablePortsDoesNotCrash() {
        // Just that enumeration works — the machine may have no serial ports.
        _ = SerialPort.available()
    }

    // MARK: - round trip over a pty

    func testBytesTravelBothWaysOverAPTY() throws {
        // Master side we drive by hand; the slave path is the "serial device".
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try XCTSkipUnless(master >= 0, "could not open a pty")
        defer { close(master) }
        guard grantpt(master) == 0, unlockpt(master) == 0,
              let namePtr = ptsname(master) else {
            throw XCTSkip("could not set up the pty slave")
        }
        let slavePath = String(cString: namePtr)

        let received = Received()
        let exited = XCTestExpectation(description: "onExit called")
        let conn = try SerialConnection.connect(
            device: slavePath,
            settings: SerialSettings(baud: 9600, format: "8N1"),
            onData: { received.append($0) },
            onExit: { _ in exited.fulfill() })

        // Device -> pane: write on the master, SerialConnection should read it.
        writeAll(master, "hello-from-device\n")
        wait(until: { received.text.contains("hello-from-device") }, timeout: 3)
        XCTAssertTrue(received.text.contains("hello-from-device"),
                      "SerialConnection did not deliver device output, got: \(received.text)")

        // Pane -> device: SerialConnection.write, read it back on the master.
        conn.write(Data("ls -la\n".utf8))
        let echoed = readAvailable(master, timeout: 3)
        XCTAssertTrue(echoed.contains("ls -la"),
                      "device did not receive what the pane sent, got: \(echoed)")

        // Device goes away (master closed) -> slave read hits EOF -> onExit.
        close(master)
        XCTAssertEqual(XCTWaiter().wait(for: [exited], timeout: 3), .completed,
                       "onExit was not called when the device disappeared")

        // close() after the device already went is a harmless no-op.
        conn.close()
    }

    // MARK: - helpers

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
    }

    private func writeAll(_ fd: Int32, _ string: String) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    private func readAvailable(_ fd: Int32, timeout: TimeInterval) -> String {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 1024)
        while Date() < deadline {
            var set = fd_set()
            fdZero(&set); fdSet(fd, &set)
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)
            if select(fd + 1, &set, nil, nil, &tv) > 0 {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 { out.append(contentsOf: buf[0..<n]) }
                if String(decoding: out, as: UTF8.self).contains("ls -la") { break }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func wait(until cond: @escaping () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

// fd_set helpers (Swift does not expose FD_ZERO/FD_SET).
private func fdZero(_ set: inout fd_set) {
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let index = Int(fd) / 32
    let bit = Int32(1) << (Int32(fd) % 32)
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { $0[index] |= bit }
    }
}

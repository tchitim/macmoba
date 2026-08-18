import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import MacMobaCore

final class ExpectSequenceTests: XCTestCase {

    // MARK: - pure state machine

    func testMatchesAcrossChunks() {
        // The prompt arrives split over two reads — a real terminal does this.
        let m = ExpectMachine(steps: [ExpectStep(expect: "login:", send: "admin\n")])
        XCTAssertEqual(m.feed("Welcome\r\nlog"), [])
        XCTAssertFalse(m.isComplete)
        XCTAssertEqual(m.feed("in: "), ["admin\n"])
        XCTAssertTrue(m.isComplete)
    }

    func testMultiStepLoginFlow() {
        let m = ExpectMachine(steps: [
            ExpectStep(expect: "Username:", send: "root\n"),
            ExpectStep(expect: "Password:", send: "hunter2\n"),
            ExpectStep(expect: "$", send: "uptime\n"),
        ])
        XCTAssertEqual(m.feed("Username: "), ["root\n"])
        XCTAssertEqual(m.feed("Password: "), ["hunter2\n"])
        XCTAssertEqual(m.feed("user@host:~$ "), ["uptime\n"])
        XCTAssertTrue(m.isComplete)
    }

    func testSeveralPromptsInOneChunk() {
        // If output is buffered and arrives all at once, still fire in order.
        let m = ExpectMachine(steps: [
            ExpectStep(expect: "A:", send: "1\n"),
            ExpectStep(expect: "B:", send: "2\n"),
        ])
        XCTAssertEqual(m.feed("A: 1 done\nB: "), ["1\n", "2\n"])
        XCTAssertTrue(m.isComplete)
    }

    func testSamePromptTextDoesNotSatisfyTwoSteps() {
        // Two steps both waiting for "> " must need two separate occurrences.
        let m = ExpectMachine(steps: [
            ExpectStep(expect: "> ", send: "a\n"),
            ExpectStep(expect: "> ", send: "b\n"),
        ])
        XCTAssertEqual(m.feed("> "), ["a\n"])        // only the first fires
        XCTAssertFalse(m.isComplete)
        XCTAssertEqual(m.feed("> "), ["b\n"])        // second needs a new prompt
        XCTAssertTrue(m.isComplete)
    }

    func testRegexStep() {
        let m = ExpectMachine(steps: [
            ExpectStep(expect: #"[Pp]assword:\s*"#, send: "secret\n", isRegex: true),
        ])
        XCTAssertEqual(m.feed("Enter password: "), ["secret\n"])
    }

    func testNoMatchSendsNothing() {
        let m = ExpectMachine(steps: [ExpectStep(expect: "yes/no", send: "yes\n")])
        XCTAssertEqual(m.feed("nothing relevant here\n"), [])
        XCTAssertFalse(m.isComplete)
    }

    // MARK: - text (de)serialization for the editor

    func testParseLinesLiteralAndRegexAndEscapes() {
        let text = """
        Username: => root\\n
        /[Pp]assword:/ => hunter2\\n

        > => uptime\\n
        """
        let steps = ExpectStep.parseLines(text)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0], ExpectStep(expect: "Username:", send: "root\n"))
        XCTAssertEqual(steps[1], ExpectStep(expect: "[Pp]assword:", send: "hunter2\n", isRegex: true))
        XCTAssertEqual(steps[2], ExpectStep(expect: ">", send: "uptime\n"))
    }

    func testParseLinesSkipsMalformed() {
        let steps = ExpectStep.parseLines("no arrow here\n=> emptyExpect\nok => yes\n")
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].expect, "ok")
    }

    func testFormatRoundTrips() {
        let steps = [
            ExpectStep(expect: "login:", send: "admin\n"),
            ExpectStep(expect: "pass.*:", send: "pw\r", isRegex: true),
        ]
        let text = ExpectStep.formatLines(steps)
        XCTAssertEqual(ExpectStep.parseLines(text), steps)
    }

    func testSessionConfigCarriesExpectSequenceThroughCodable() throws {
        var cfg = SessionConfig(name: "x", host: "h", username: "u")
        cfg.expectSequence = [ExpectStep(expect: "login:", send: "u\n")]
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(SessionConfig.self, from: data)
        XCTAssertEqual(back.expectSequence, cfg.expectSequence)

        // A vault written before this field existed still decodes (field absent).
        let legacy = #"{"id":"1","name":"x","host":"h","port":22,"username":"u","authType":"password"}"#
        let old = try JSONDecoder().decode(SessionConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(old.expectSequence)
    }

    // MARK: - end to end over a pty via SerialConnection

    func testDrivesALoginOverAPTY() throws {
        // A pty stands in for the remote: the master side plays the server that
        // prints prompts; SerialConnection is the client whose output feeds the
        // ExpectMachine, whose sends are written back to the connection.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try XCTSkipUnless(master >= 0, "no pty")
        defer { close(master) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let namePtr = ptsname(master) else {
            throw XCTSkip("pty setup failed")
        }
        let slavePath = String(cString: namePtr)

        let machine = ExpectMachine(steps: [
            ExpectStep(expect: "login:", send: "admin\n"),
            ExpectStep(expect: "Password:", send: "s3cret\n"),
        ])
        let done = XCTestExpectation(description: "login sequence completed")

        var conn: SerialConnection!
        conn = try SerialConnection.connect(
            device: slavePath,
            settings: SerialSettings(baud: 9600, format: "8N1"),
            onData: { data in
                let text = String(decoding: data, as: UTF8.self)
                for send in machine.feed(text) {
                    conn.write(Data(send.utf8))
                }
                if machine.isComplete { done.fulfill() }
            },
            onExit: { _ in })
        defer { conn.close() }

        // Server side: print the first prompt, wait for the client's answer,
        // then the second.
        writeStr(master, "line 1\r\nlogin: ")
        let user = readUntil(master, "admin", timeout: 3)
        XCTAssertTrue(user.contains("admin"), "machine did not send the username, saw: \(user)")

        writeStr(master, "\r\nPassword: ")
        let pass = readUntil(master, "s3cret", timeout: 3)
        XCTAssertTrue(pass.contains("s3cret"), "machine did not send the password, saw: \(pass)")

        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 3), .completed)
        XCTAssertTrue(machine.isComplete)
    }

    // MARK: - helpers

    private func writeStr(_ fd: Int32, _ s: String) {
        var bytes = Array(s.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func readUntil(_ fd: Int32, _ needle: String, timeout: TimeInterval) -> String {
        var out = ""
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 512)
        while Date() < deadline {
            var set = fd_set(); fdZero(&set); fdSet(fd, &set)
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)
            if select(fd + 1, &set, nil, nil, &tv) > 0 {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 { out += String(decoding: buf[0..<n], as: UTF8.self) }
                if out.contains(needle) { break }
            }
        }
        return out
    }
}

// fd_set helpers (Swift hides the C macros).
private func fdZero(_ set: inout fd_set) { bzero(&set, MemoryLayout<fd_set>.size) }
private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: Int(FD_SETSIZE) / 32) {
            $0[Int(fd) / 32] |= Int32(1) << (Int32(fd) % 32)
        }
    }
}

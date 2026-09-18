import XCTest
@testable import MacMobaCore

final class BatchRunTests: XCTestCase {

    // MARK: - the bounded scheduler

    /// Every input is processed exactly once, however the concurrency falls.
    func testRunProcessesEveryInputOnce() async {
        let counter = Counter()
        let inputs = Array(0..<20)
        await BatchRun.run(inputs, maxConcurrent: 4) { _ in
            await counter.tick()
        }
        let seen = await counter.total
        XCTAssertEqual(seen, 20)
    }

    /// The cap is honoured: with room for 3 at a time, no more than 3 are ever
    /// in flight at once.
    func testRunNeverExceedsTheCap() async {
        let tracker = ConcurrencyTracker()
        await BatchRun.run(Array(0..<12), maxConcurrent: 3) { _ in
            await tracker.enter()
            // Hold the slot long enough that, without a cap, more than three
            // would pile up here at once.
            try? await Task.sleep(nanoseconds: 5_000_000)
            await tracker.leave()
        }
        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 3, "peak concurrency \(peak) exceeded the cap of 3")
        XCTAssertGreaterThan(peak, 1, "nothing ran concurrently — the cap wasn't the limiter")
    }

    /// A cap of zero (or less) is clamped to one rather than deadlocking on an
    /// empty task group, so a run still completes.
    func testRunClampsNonPositiveCapToSerial() async {
        let tracker = ConcurrencyTracker()
        await BatchRun.run(Array(0..<5), maxConcurrent: 0) { _ in
            await tracker.enter()
            try? await Task.sleep(nanoseconds: 1_000_000)
            await tracker.leave()
        }
        let peak = await tracker.peak
        let total = await tracker.total
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(total, 5)
    }

    func testRunOnEmptyInputIsANoOp() async {
        let counter = Counter()
        await BatchRun.run([Int](), maxConcurrent: 4) { _ in await counter.tick() }
        let seen = await counter.total
        XCTAssertEqual(seen, 0)
    }

    // MARK: - the report

    private let fixedTime = Date(timeIntervalSince1970: 1_726_663_927) // 2024-09-18 …
    private let utc = TimeZone(identifier: "UTC")!

    func testReportSummarisesCountsAndNamesHostsNotIds() {
        let results = [
            BatchRun.Result(name: "RaspberryPi4", host: "192.168.88.2",
                            outcome: .ok, output: "up 3 days", durationMs: 412),
            BatchRun.Result(name: "Arch", host: "192.168.88.3",
                            outcome: .failed("connect timed out"), output: "", durationMs: 2100),
        ]
        let md = BatchRun.report(command: "uptime", results: results,
                                 startedAt: fixedTime, timeZone: utc)
        XCTAssertTrue(md.contains("(2 hosts, 1 ok, 1 failed)"), md)
        // Names, not ids or hosts, head each section.
        XCTAssertTrue(md.contains("### RaspberryPi4 — ok (0.4s)"), md)
        XCTAssertTrue(md.contains("### Arch — failed — connect timed out (2.1s)"), md)
        // The command is fenced, and a host's output is fenced under it.
        XCTAssertTrue(md.contains("```\nuptime\n```"), md)
        XCTAssertTrue(md.contains("up 3 days"), md)
    }

    /// A host with no output prints its heading but no empty code fence.
    func testReportOmitsEmptyOutputFence() {
        let results = [BatchRun.Result(name: "web1", host: "h", outcome: .ok,
                                       output: "   \n  ", durationMs: 50)]
        let md = BatchRun.report(command: "true", results: results,
                                 startedAt: fixedTime, timeZone: utc)
        XCTAssertTrue(md.contains("### web1 — ok (0.1s)"), md)
        // Only the command fence — the (blank) output adds none of its own.
        XCTAssertEqual(md.components(separatedBy: "```").count - 1, 2, md)
    }

    func testReportCountsCancelled() {
        let results = [
            BatchRun.Result(name: "a", host: "h", outcome: .ok, output: "", durationMs: 10),
            BatchRun.Result(name: "b", host: "h", outcome: .cancelled, output: "", durationMs: 0),
        ]
        let md = BatchRun.report(command: "x", results: results,
                                 startedAt: fixedTime, timeZone: utc)
        XCTAssertTrue(md.contains("(2 hosts, 1 ok, 1 cancelled)"), md)
        XCTAssertTrue(md.contains("### b — cancelled (0.0s)"), md)
    }

    /// The file stamp is sortable and carries no character a filename can't hold.
    func testFileStampIsSortableAndSafe() {
        let stamp = BatchRun.fileStamp(fixedTime, timeZone: utc)
        XCTAssertEqual(stamp, "2024-09-18-125207")
        XCTAssertFalse(stamp.contains(":"))
        XCTAssertFalse(stamp.contains(" "))
    }
}

// MARK: - test helpers

private actor Counter {
    private(set) var total = 0
    func tick() { total += 1 }
}

/// Tracks how many operations are inside the critical section at once, and the
/// high-water mark, so a test can assert the cap held.
private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0
    private(set) var total = 0
    func enter() { current += 1; total += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

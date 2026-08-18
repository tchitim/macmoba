import XCTest
@testable import MacMobaCore

final class RemoteStatsTests: XCTestCase {

    // MARK: - uptime

    func testParsesLinuxUptime() {
        let line = " 15:29:37 up 3 days,  4:05,  2 users,  load average: 0.00, 0.01, 0.05"
        let (loads, uptime, users) = RemoteStatsProbe.parseUptime(line)
        XCTAssertEqual(loads, [0.00, 0.01, 0.05])
        XCTAssertEqual(users, 2)
        XCTAssertEqual(uptime, "3 days,  4:05")
    }

    func testParsesMacUptimeWithSpaceSeparatedLoads() {
        let line = "15:29  up 5 days, 23:11, 3 users, load averages: 1.20 1.15 1.09"
        let (loads, uptime, users) = RemoteStatsProbe.parseUptime(line)
        XCTAssertEqual(loads, [1.20, 1.15, 1.09])
        XCTAssertEqual(users, 3)
        XCTAssertEqual(uptime, "5 days, 23:11")
    }

    func testUptimeSingleUser() {
        let (_, uptime, users) = RemoteStatsProbe.parseUptime(
            "10:00:00 up 12 min,  1 user,  load average: 0.10, 0.20, 0.30")
        XCTAssertEqual(users, 1)
        XCTAssertEqual(uptime, "12 min")
    }

    // MARK: - meminfo

    func testParsesMeminfoUsedFromAvailable() {
        let mem = """
        MemTotal:       16384000 kB
        MemFree:         1000000 kB
        MemAvailable:    8192000 kB
        Buffers:          200000 kB
        """
        let result = RemoteStatsProbe.parseMeminfo(mem)
        XCTAssertEqual(result?.totalKB, 16384000)
        XCTAssertEqual(result?.usedPercent ?? 0, 50.0, accuracy: 0.01)
    }

    func testMeminfoMissingIsNil() {
        XCTAssertNil(RemoteStatsProbe.parseMeminfo("nothing here"))
    }

    // MARK: - CPU

    func testCPUUsageFromTwoSamples() {
        let text = """
        cpu  100 0 100 800 0 0 0 0 0 0
        cpu  200 0 200 1400 0 0 0 0 0 0
        """
        // totalΔ=800, idleΔ=600 → 25% busy.
        XCTAssertEqual(RemoteStatsProbe.parseCPUUsage(text) ?? -1, 25.0, accuracy: 0.01)
    }

    func testCPUUsageNeedsTwoSamples() {
        XCTAssertNil(RemoteStatsProbe.parseCPUUsage("cpu  100 0 100 800 0 0 0 0"))
    }

    // MARK: - full pipeline

    func testParsesCombinedCommandOutput() {
        let output = """
         09:00:01 up 2 days,  1:30,  4 users,  load average: 0.50, 0.40, 0.30
        \(RemoteStatsProbe.memMarker)
        MemTotal:       8000000 kB
        MemAvailable:   2000000 kB
        \(RemoteStatsProbe.cpuMarker)
        cpu  100 0 100 800 0 0 0 0 0 0
        cpu  200 0 200 1400 0 0 0 0 0 0
        """
        let s = RemoteStatsProbe.parse(output)
        XCTAssertEqual(s.loadAverages, [0.50, 0.40, 0.30])
        XCTAssertEqual(s.users, 4)
        XCTAssertEqual(s.uptimeText, "2 days,  1:30")
        XCTAssertEqual(s.memTotalKB, 8000000)
        XCTAssertEqual(s.memUsedPercent ?? 0, 75.0, accuracy: 0.01)   // (8000-2000)/8000
        XCTAssertEqual(s.cpuUsedPercent ?? -1, 25.0, accuracy: 0.01)
    }

    func testBoxWithoutProcStillGivesLoad() {
        // macOS/BSD: no /proc, so mem and cpu sections are empty.
        let output = """
        15:29  up 5 days, 23:11, 3 users, load averages: 1.20 1.15 1.09
        \(RemoteStatsProbe.memMarker)
        \(RemoteStatsProbe.cpuMarker)
        """
        let s = RemoteStatsProbe.parse(output)
        XCTAssertEqual(s.loadAverages, [1.20, 1.15, 1.09])
        XCTAssertNil(s.memUsedPercent)
        XCTAssertNil(s.cpuUsedPercent)
    }

    func testGarbageDoesNotCrash() {
        let s = RemoteStatsProbe.parse("permission denied\n\n???")
        XCTAssertTrue(s.loadAverages.isEmpty)
        XCTAssertNil(s.memUsedPercent)
    }
}

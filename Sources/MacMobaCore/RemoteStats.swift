// The little "how's the server doing" readout MobaXterm shows for an SSH
// session: load average, memory use, CPU use, uptime. It is gathered by running
// one throwaway command over SSH and parsing the text — no agent on the far end.
//
// Only the parsing lives here, and it is the whole point: fed the exact bytes a
// real `uptime` / `/proc/meminfo` / `/proc/stat` produce, it must pull the right
// numbers out, tolerate a box that has no `/proc` (macOS, BSD), and never throw
// on junk. That is all unit-testable with fixtures, no server required.

import Foundation

public struct RemoteStats: Equatable, Sendable {
    /// 1-, 5-, 15-minute load averages (as many as were found).
    public var loadAverages: [Double]
    /// Human uptime, e.g. "3 days, 4:05".
    public var uptimeText: String?
    public var users: Int?
    public var memTotalKB: Int?
    public var memUsedPercent: Double?
    public var cpuUsedPercent: Double?

    public init(loadAverages: [Double] = [], uptimeText: String? = nil, users: Int? = nil,
                memTotalKB: Int? = nil, memUsedPercent: Double? = nil,
                cpuUsedPercent: Double? = nil) {
        self.loadAverages = loadAverages
        self.uptimeText = uptimeText
        self.users = users
        self.memTotalKB = memTotalKB
        self.memUsedPercent = memUsedPercent
        self.cpuUsedPercent = cpuUsedPercent
    }
}

public enum RemoteStatsProbe {
    static let memMarker = "@@MMBMEM@@"
    static let cpuMarker = "@@MMBCPU@@"

    /// One command that prints uptime, memory, and two CPU snapshots 0.4s apart
    /// (a CPU percentage needs two samples). `2>/dev/null` so a box without
    /// `/proc` simply omits those sections instead of erroring.
    public static var command: String {
        "uptime; echo '\(memMarker)'; cat /proc/meminfo 2>/dev/null;"
        + " echo '\(cpuMarker)'; grep '^cpu ' /proc/stat 2>/dev/null;"
        + " sleep 0.4; grep '^cpu ' /proc/stat 2>/dev/null"
    }

    /// Parse the combined output of `command`.
    public static func parse(_ output: String) -> RemoteStats {
        let memParts = output.components(separatedBy: memMarker)
        let uptimeSection = memParts.first ?? output
        let rest = memParts.count > 1 ? memParts[1] : ""
        let cpuParts = rest.components(separatedBy: cpuMarker)
        let memSection = cpuParts.first ?? ""
        let cpuSection = cpuParts.count > 1 ? cpuParts[1] : ""

        var stats = RemoteStats()
        let (loads, uptime, users) = parseUptime(uptimeSection)
        stats.loadAverages = loads
        stats.uptimeText = uptime
        stats.users = users
        if let (total, usedPct) = parseMeminfo(memSection) {
            stats.memTotalKB = total
            stats.memUsedPercent = usedPct
        }
        stats.cpuUsedPercent = parseCPUUsage(cpuSection)
        return stats
    }

    // MARK: - uptime

    /// Handles both Linux (`load average: 0.00, 0.01, 0.05`) and macOS/BSD
    /// (`load averages: 1.20 1.15 1.09`).
    static func parseUptime(_ text: String) -> (loads: [Double], uptime: String?, users: Int?) {
        let line = text.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("load average") }) ?? Substring(text)

        var loads: [Double] = []
        if let range = line.range(of: "load average", options: .caseInsensitive) {
            // Everything after the colon that follows "load average(s)".
            let tail = line[range.upperBound...].drop(while: { $0 != ":" }).dropFirst()
            loads = tail.split(whereSeparator: { $0 == "," || $0 == " " })
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }

        var users: Int?
        if let uRange = line.range(of: #"(\d+)\s+users?"#, options: .regularExpression) {
            users = Int(line[uRange].prefix(while: { $0.isNumber }))
        }

        var uptime: String?
        if let upRange = line.range(of: " up ") {
            let after = line[upRange.upperBound...]
            // Up to the ", N user(s)" clause.
            if let userClause = after.range(of: #",\s+\d+\s+users?"#, options: .regularExpression) {
                uptime = String(after[..<userClause.lowerBound]).trimmingCharacters(in: .whitespaces)
            } else {
                uptime = String(after).trimmingCharacters(in: .whitespaces)
            }
        }
        return (loads, uptime, users)
    }

    // MARK: - meminfo

    /// Returns (MemTotal kB, used percent) from /proc/meminfo. "Used" is total
    /// minus MemAvailable — the number that actually reflects pressure, not the
    /// misleading total-minus-free.
    static func parseMeminfo(_ text: String) -> (totalKB: Int, usedPercent: Double)? {
        var total: Int?
        var available: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("MemTotal:") { total = firstInt(in: line) }
            else if line.hasPrefix("MemAvailable:") { available = firstInt(in: line) }
        }
        guard let total, total > 0, let available else { return nil }
        let used = Double(total - available) / Double(total) * 100
        return (total, max(0, min(100, used)))
    }

    // MARK: - CPU

    /// Two `cpu ...` lines from /proc/stat, 0.4s apart, give a usage percentage
    /// from the change in idle vs total jiffies. Needs both lines; one is not
    /// enough to say anything.
    static func parseCPUUsage(_ text: String) -> Double? {
        let lines = text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("cpu ") }
            .map { fields(after: "cpu", in: $0) }
        guard lines.count >= 2 else { return nil }
        let a = lines[lines.count - 2], b = lines[lines.count - 1]
        guard a.count >= 5, b.count >= 5 else { return nil }

        let idleA = a[3] + a[4]                 // idle + iowait
        let idleB = b[3] + b[4]
        let totalA = a.reduce(0, +)
        let totalB = b.reduce(0, +)
        let totalDelta = totalB - totalA
        let idleDelta = idleB - idleA
        guard totalDelta > 0 else { return nil }
        let usage = (1 - Double(idleDelta) / Double(totalDelta)) * 100
        return max(0, min(100, usage))
    }

    private static func fields(after keyword: String, in line: Substring) -> [Int] {
        line.split(separator: " ").drop(while: { $0 == keyword })
            .compactMap { Int($0) }
    }

    private static func firstInt(in line: Substring) -> Int? {
        line.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
    }
}

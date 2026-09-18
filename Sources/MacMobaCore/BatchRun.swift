// Batch Run: one command set, run across many saved SSH hosts, results
// collected and written to an append-only log.
//
// This file holds only the parts with nothing to do with SSH or the UI — the
// bounded scheduler, the result model, and the report — so they are unit
// testable without a network. The KKTerm rules this borrows, kept deliberately:
//
//  * A run owns WHAT to run, never its targets. The hosts are passed in; a run
//    is a command plus a selection, not a saved object that owns machines.
//  * The report names hosts by NAME, not id (soft reference). A host deleted
//    from the session list later still reads back in an old report.
//
// The live per-host status and the actual `runCommand` calls live in the app
// target, which drives `run(_:maxConcurrent:operation:)` and feeds the finished
// rows to `report`.

import Foundation

public enum BatchRun {

    /// The end state of one host in a run.
    public enum Outcome: Equatable, Sendable {
        /// Reached the host and ran the command. This says nothing about the
        /// command's own exit status — the output is where that shows — only
        /// that the SSH login and exec succeeded.
        case ok
        /// Never got that far: the connection, auth, or exec failed. The string
        /// is the reason, trimmed to one line.
        case failed(String)
        /// The run was cancelled before this host started.
        case cancelled
    }

    /// One host's result, as the report and the log see it. `name`, not id:
    /// the soft-reference rule — the record outlives the session it names.
    public struct Result: Sendable, Equatable {
        public let name: String
        public let host: String
        public let outcome: Outcome
        public let output: String
        public let durationMs: Int

        public init(name: String, host: String, outcome: Outcome,
                    output: String, durationMs: Int) {
            self.name = name
            self.host = host
            self.outcome = outcome
            self.output = output
            self.durationMs = durationMs
        }

        public var ok: Bool { outcome == .ok }
    }

    /// Run `operation` over every input, at most `maxConcurrent` at a time: the
    /// classic bounded task group — prime up to the cap, then start one more
    /// each time one finishes. `operation` reports its own outcome by side
    /// effect (the caller updates its rows), so this returns nothing and simply
    /// completes when every input has been processed.
    ///
    /// The cap exists because a batch is aimed at a whole folder of hosts, and
    /// opening thirty SSH logins at once floods the Mac's file descriptors and
    /// hammers a shared bastion. A small cap keeps a run brisk without the
    /// thundering herd; the caller passes 4.
    public static func run<Input: Sendable>(
        _ inputs: [Input],
        maxConcurrent: Int,
        operation: @Sendable @escaping (Input) async -> Void
    ) async {
        let cap = max(1, maxConcurrent)
        var next = 0
        await withTaskGroup(of: Void.self) { group in
            while next < inputs.count && next < cap {
                let input = inputs[next]; next += 1
                group.addTask { await operation(input) }
            }
            while await group.next() != nil {
                guard next < inputs.count else { continue }
                let input = inputs[next]; next += 1
                group.addTask { await operation(input) }
            }
        }
    }

    /// One run's report, as Markdown. Written under `<logs>/batch/<stamp>.md`,
    /// one file per run, never rewritten — the folder itself is the history.
    /// Hosts appear by name, ordered as `results` is (the caller keeps the
    /// selection order). The timezone is injectable so the output is testable.
    public static func report(command: String,
                              results: [Result],
                              startedAt: Date,
                              timeZone: TimeZone = .current) -> String {
        let okCount = results.filter { $0.outcome == .ok }.count
        let failedCount = results.filter {
            if case .failed = $0.outcome { return true }; return false
        }.count
        let cancelledCount = results.filter { $0.outcome == .cancelled }.count

        var summary = "\(results.count) host\(results.count == 1 ? "" : "s"), \(okCount) ok"
        if failedCount > 0 { summary += ", \(failedCount) failed" }
        if cancelledCount > 0 { summary += ", \(cancelledCount) cancelled" }

        var lines: [String] = []
        lines.append("## \(humanStamp(startedAt, timeZone: timeZone))  (\(summary))")
        lines.append("")
        lines.append("Command:")
        lines.append("```")
        lines.append(command.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("```")
        lines.append("")
        for r in results {
            let secs = String(format: "%.1fs", Double(r.durationMs) / 1000)
            let state: String
            switch r.outcome {
            case .ok: state = "ok"
            case .failed(let reason): state = "failed — \(reason)"
            case .cancelled: state = "cancelled"
            }
            lines.append("### \(r.name) — \(state) (\(secs))")
            let body = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                lines.append("```")
                lines.append(body)
                lines.append("```")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The `<stamp>` used in the report filename, e.g. `2026-09-18-143207`.
    /// Sortable and filesystem-safe (no `:`), so a directory listing is a
    /// chronological history.
    public static func fileStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd-HHmmss", timeZone).string(from: date)
    }

    /// Human-readable time for the report heading, e.g. `2026-09-18 14:32:07`.
    static func humanStamp(_ date: Date, timeZone: TimeZone) -> String {
        formatter("yyyy-MM-dd HH:mm:ss", timeZone).string(from: date)
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}

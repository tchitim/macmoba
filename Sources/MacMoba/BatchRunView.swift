// Tools ▸ Batch Run: pick saved SSH sessions, type a command, run it across all
// of them at once, watch each host's result land, and get an append-only log.
//
// The scheduling and the report live in MacMobaCore.BatchRun (unit tested); this
// file is the app side — the per-host `runCommand` over each session's own jump
// chain and credentials, the live rows, and writing the log next to the session
// logs. It borrows the same command primitive `remoteStats` and the Mosh probe
// already use, so a batch reaches a host exactly the way a real connect does.

import MacMobaCore
import SwiftUI
import AppKit

@MainActor
final class BatchRunModel: ObservableObject {
    /// At most this many hosts run at once. A batch is aimed at a whole folder,
    /// and thirty simultaneous SSH logins flood the Mac and any shared bastion;
    /// four keeps a run brisk without the thundering herd.
    static let maxConcurrent = 4

    enum Phase: Equatable {
        case queued
        case running
        case done(BatchRun.Outcome)
    }

    struct Row: Identifiable {
        let id: String            // the session id
        let name: String
        let host: String
        var phase: Phase = .queued
        var output = ""
        var durationMs = 0
    }

    @Published var command = ""
    /// Remembered across launches: the last set of hosts, so a batch you run
    /// often is one click away. Stored as session ids; a deleted session just
    /// drops out of the picker.
    @Published var selected: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(selected), forKey: Self.selectionKey) }
    }
    @Published var rows: [Row] = []
    @Published var isRunning = false
    @Published var reportURL: URL?

    private static let selectionKey = "batchRunSelection"
    private var task: Task<Void, Never>?
    private unowned var app: AppState!

    init() {
        if let saved = UserDefaults.standard.array(forKey: Self.selectionKey) as? [String] {
            selected = Set(saved)
        }
    }

    // MARK: - the picker

    /// SSH sessions only (a batch runs a shell command; VNC/RDP/serial have no
    /// shell to run it in), grouped by sidebar folder, folders and hosts sorted
    /// so the list is stable between runs.
    func groups(in app: AppState) -> [(folder: String, sessions: [SessionConfig])] {
        let ssh = app.data.sessions.filter { $0.sessionKind == .ssh }
        return Dictionary(grouping: ssh) { $0.group ?? "" }
            .map { (folder: $0.key.isEmpty ? "Ungrouped" : $0.key,
                    sessions: $0.value.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }) }
            .sorted { $0.folder.localizedCompare($1.folder) == .orderedAscending }
    }

    /// Selected SSH sessions in the picker's own order — the order the run and
    /// the report follow.
    func orderedTargets(in app: AppState) -> [SessionConfig] {
        groups(in: app).flatMap(\.sessions).filter { selected.contains($0.id) }
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(get: { self.selected.contains(id) },
                set: { on in
                    if on { self.selected.insert(id) } else { self.selected.remove(id) }
                })
    }

    func select(_ ids: [String], _ on: Bool) {
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    // MARK: - the run

    func run(in app: AppState) {
        let cmd = command
        guard !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let targets = orderedTargets(in: app)
        guard !targets.isEmpty else { return }

        self.app = app
        rows = targets.map { Row(id: $0.id, name: $0.name, host: $0.host) }
        reportURL = nil
        isRunning = true
        let startedAt = Date()

        task = Task { [weak self] in
            guard let self else { return }
            await BatchRun.run(targets, maxConcurrent: Self.maxConcurrent) { session in
                await self.execute(session, command: cmd)
            }
            await self.finishRun(command: cmd, startedAt: startedAt)
        }
    }

    /// Stop launching new hosts. Ones already connecting run to completion — an
    /// SSH exec in flight can't be yanked cleanly — but nothing new starts, and
    /// the still-queued hosts are marked cancelled when the run wraps up.
    func cancel() { task?.cancel() }

    /// One host, off the main actor so `maxConcurrent` of these truly overlap.
    /// Only the row updates and the two main-actor reads (jump chain, host-key
    /// policy) hop back to the main actor; the SSH work does not.
    nonisolated private func execute(_ session: SessionConfig, command: String) async {
        await setRunning(session.id)
        let started = Date()
        let route = await MainActor.run {
            (config: session,
             chain: self.app.jumpChain(for: session),
             hostKeys: self.app.hostKeyVerification)
        }
        do {
            let resolved = try await SecretResolver.resolve(session: route.config)
            let resolvedChain = try await SecretResolver.resolve(sessions: route.chain)
            let output = try await SSHConnection.runCommand(
                command, config: resolved, hostKeys: route.hostKeys,
                jumps: resolvedChain, timeoutSeconds: 120)
            await finishRow(session.id, .done(.ok), output: output, since: started)
        } catch {
            let outcome: BatchRun.Outcome = Task.isCancelled
                ? .cancelled : .failed(Self.oneLine(error))
            await finishRow(session.id, .done(outcome), output: "", since: started)
        }
    }

    private func setRunning(_ id: String) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].phase = .running }
    }

    private func finishRow(_ id: String, _ phase: Phase, output: String, since: Date) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].phase = phase
        rows[i].output = output
        rows[i].durationMs = Int(Date().timeIntervalSince(since) * 1000)
    }

    private func finishRun(command: String, startedAt: Date) {
        // Anything not finished when the group ended was cancelled (the run was
        // stopped before it started).
        for i in rows.indices where !isDone(rows[i].phase) {
            rows[i].phase = .done(.cancelled)
        }
        writeReport(command: command, startedAt: startedAt)
        isRunning = false
    }

    private func isDone(_ phase: Phase) -> Bool {
        if case .done = phase { return true }; return false
    }

    private func writeReport(command: String, startedAt: Date) {
        let results = rows.map { row -> BatchRun.Result in
            let outcome: BatchRun.Outcome
            if case .done(let o) = row.phase { outcome = o } else { outcome = .cancelled }
            return BatchRun.Result(name: row.name, host: row.host, outcome: outcome,
                                   output: row.output, durationMs: row.durationMs)
        }
        let markdown = BatchRun.report(command: command, results: results, startedAt: startedAt)
        let dir = SessionLogger.directory.appendingPathComponent("batch", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(BatchRun.fileStamp(startedAt)).md")
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            reportURL = url
        } catch {
            // Non-fatal: the results are on screen even if the log write failed.
            reportURL = nil
        }
    }

    nonisolated private static func oneLine(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

struct BatchRunView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model = BatchRunModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Run").font(.headline)
            Text("Run a command on several saved SSH sessions at once. "
                 + "Up to \(BatchRunModel.maxConcurrent) run in parallel; "
                 + "the results are written to a log you can revisit.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                targetPicker
                commandEditor
            }
            .frame(height: 200)

            controls
            if !model.rows.isEmpty { results }
            footer
        }
        .padding(20)
        .frame(width: 760, height: 620)
    }

    private var targetPicker: some View {
        GroupBox("Hosts") {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let groups = model.groups(in: app)
                    if groups.isEmpty {
                        Text("No saved SSH sessions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.folder) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(group.folder).font(.subheadline).bold()
                                Spacer()
                                Button("All") { model.select(group.sessions.map(\.id), true) }
                                    .buttonStyle(.link).font(.caption)
                                Button("None") { model.select(group.sessions.map(\.id), false) }
                                    .buttonStyle(.link).font(.caption)
                            }
                            ForEach(group.sessions, id: \.id) { session in
                                Toggle(isOn: model.binding(for: session.id)) {
                                    HStack(spacing: 6) {
                                        Text(session.name)
                                        Text(session.host)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        .frame(width: 320)
    }

    private var commandEditor: some View {
        GroupBox("Command") {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $model.command)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Runs on each host over its own SSH connection. "
                     + "Multiple lines run as one script; stdout and stderr are captured.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private var controls: some View {
        HStack {
            Text("\(model.orderedTargets(in: app).count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.isRunning {
                Button("Cancel") { model.cancel() }
            }
            Button("Run") { model.run(in: app) }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isRunning
                          || model.orderedTargets(in: app).isEmpty
                          || model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var results: some View {
        List(model.rows) { row in
            DisclosureGroup {
                if row.output.isEmpty {
                    Text("(no output)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(row.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                HStack(spacing: 8) {
                    statusIcon(row.phase)
                    Text(row.name)
                    Text(row.host).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if case .done = row.phase {
                        Text(String(format: "%.1fs", Double(row.durationMs) / 1000))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minHeight: 150)
    }

    @ViewBuilder
    private func statusIcon(_ phase: BatchRunModel.Phase) -> some View {
        switch phase {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done(.ok):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .done(.failed):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .done(.cancelled):
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if let url = model.reportURL {
                Text("Report: \(url.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .font(.caption)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
}

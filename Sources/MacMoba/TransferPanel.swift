// Two-pane transfer: this Mac on the left, the server on the right.
//
// The single-pane browser is for poking around a server; this is for moving a
// pile of files and knowing what happened to each one. Both panes are the same
// view over the same model, because both sides speak `RemoteFileService` — the
// local one included.

import AppKit
import MacMobaCore
import SwiftUI

// MARK: - One pane

@MainActor
final class TransferPaneModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    @Published var state: State = .connecting
    @Published var path = "/"
    @Published var pathField = "/"
    @Published var items: [SFTPItem] = []
    /// Names, not indices: the list is re-sorted and reloaded constantly, and
    /// an index-based selection silently starts pointing at another file.
    @Published var selection: Set<String> = []
    @Published var errorMessage: String?
    /// Sort choice, remembered across launches: a preference about how you
    /// read a directory, not something to re-pick every session.
    @Published var sortKey: FileSortKey {
        didSet {
            guard sortKey != oldValue else { return }
            // Picking a key implies its natural direction — "by date" means
            // newest first — but an explicit flip afterwards is respected.
            ascending = !sortKey.prefersDescending
            UserDefaults.standard.set(sortKey.rawValue, forKey: Self.sortKeyDefault)
            resort()
        }
    }
    @Published var ascending: Bool {
        didSet {
            guard ascending != oldValue else { return }
            UserDefaults.standard.set(ascending, forKey: Self.ascendingDefault)
            resort()
        }
    }

    private static let sortKeyDefault = "transferSortKey"
    private static let ascendingDefault = "transferSortAscending"
    /// The listing as the server gave it; re-sorted rather than re-fetched
    /// when the order changes.
    private var unsorted: [SFTPItem] = []

    let title: String
    let isLocal: Bool
    private(set) var service: RemoteFileService?
    private let connect: () async throws -> RemoteFileService

    init(title: String, isLocal: Bool,
         connect: @escaping () async throws -> RemoteFileService) {
        self.title = title
        self.isLocal = isLocal
        self.connect = connect
        let stored = UserDefaults.standard.string(forKey: Self.sortKeyDefault)
        let key = stored.flatMap(FileSortKey.init(rawValue:)) ?? .name
        self.sortKey = key
        self.ascending = UserDefaults.standard.object(forKey: Self.ascendingDefault) as? Bool
            ?? !key.prefersDescending
    }

    private func resort() {
        items = FileSort.sort(unsorted, by: sortKey, ascending: ascending)
    }

    func start() {
        guard service == nil else { return }
        state = .connecting
        Task {
            do {
                let service = try await connect()
                self.service = service
                let home = try await service.realpath(".")
                self.state = .ready
                await load(home)
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func close() {
        if let service, !isLocal {
            Task { await service.close() }
        }
        service = nil
    }

    func load(_ newPath: String) async {
        guard let service else { return }
        do {
            let resolved = try await service.realpath(newPath)
            let listing = try await service.list(resolved)
            path = resolved
            pathField = resolved
            unsorted = listing
            resort()
            // A selection that survived a reload would transfer whatever now
            // holds those names.
            selection = selection.intersection(Set(items.map(\.name)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() { Task { await load(path) } }

    func enter(_ item: SFTPItem) {
        guard item.isDirectory else { return }
        Task { await load(FTPProtocol.join(path, item.name)) }
    }

    func goUp() {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        Task { await load(parent.isEmpty ? "/" : parent) }
    }

    func submitPathField() {
        Task { await load(pathField) }
    }

    var selectedItems: [SFTPItem] {
        items.filter { selection.contains($0.name) }
    }

    // MARK: - Editing

    /// Names in this folder, so a rename can be checked before it is sent.
    var existingNames: Set<String> { Set(items.map(\.name)) }

    func rename(_ item: SFTPItem, to newName: String) {
        guard let service else { return }
        let cleaned = FileNameCheck.cleaned(newName)
        guard cleaned != item.name else { return }
        if let rejection = FileNameCheck.rejection(for: newName, existing: existingNames,
                                                  currentName: item.name) {
            errorMessage = rejection
            return
        }
        let from = FTPProtocol.join(path, item.name)
        let to = FTPProtocol.join(path, cleaned)
        Task {
            do {
                try await service.rename(from, to: to)
                await load(path)
            } catch {
                errorMessage = "Could not rename \(item.name): \(error.localizedDescription)"
            }
        }
    }

    /// Delete, permanently on a server and to the Trash on this Mac.
    ///
    /// A remote delete cannot be undone — there is no trash on the far end —
    /// which is why the caller confirms first and why the local side goes to
    /// the Trash instead of being unlinked.
    func delete(_ items: [SFTPItem]) {
        guard let service, !items.isEmpty else { return }
        Task {
            for item in items {
                do {
                    if isLocal {
                        try FileManager.default.trashItem(
                            at: URL(fileURLWithPath: FTPProtocol.join(path, item.name)),
                            resultingItemURL: nil)
                    } else if item.isDirectory {
                        try await service.removeDirectoryRecursively(
                            FTPProtocol.join(path, item.name))
                    } else {
                        try await service.removeFile(FTPProtocol.join(path, item.name))
                    }
                } catch {
                    errorMessage = "Could not delete \(item.name): \(error.localizedDescription)"
                }
            }
            selection = []
            await load(path)
        }
    }
}

// MARK: - The transfer itself

@MainActor
final class TransferController: ObservableObject {
    struct Prompt: Identifiable {
        let id = UUID()
        let job: TransferJob
        let direction: TransferDirection
        /// How many files are still to come, so "apply to all" can say what it
        /// would cover.
        let remaining: Int
    }

    @Published var running = false
    @Published var currentName = ""
    @Published var completed = 0
    @Published var total = 0
    /// Bytes of the file being copied right now, and its size.
    ///
    /// The panel used to show only "name (1 of 1)" beside an indeterminate
    /// spinner, so a single large file — the case this panel exists for — gave
    /// no sign of progress at all for as long as it took. Every transfer call
    /// here passed `progress: nil`, so the figures were never even asked for.
    @Published var fileDone: UInt64 = 0
    @Published var fileTotal: UInt64?

    /// How far through the current file, or nil when its size is unknown.
    var fileFraction: Double? {
        guard let fileTotal, fileTotal > 0 else { return nil }
        return min(1, Double(fileDone) / Double(fileTotal))
    }

    /// Progress fires per chunk; throttle the republishing.
    private var lastProgressPublish = Date.distantPast

    func reportProgress(done: UInt64, total: UInt64?) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublish) > 0.05 else { return }
        lastProgressPublish = now
        fileDone = done
        if let total { fileTotal = total }
    }

    /// What the status bar says while running.
    ///
    /// The file count stays — it is the only thing that says how much of a
    /// multi-file job is left — with the percentage and bytes for the file
    /// actually moving, since that is where the time goes.
    var progressLine: String {
        guard !currentName.isEmpty else { return "Working…" }
        var line = currentName
        if total > 1 { line += " (\(completed + 1) of \(total))" }
        if let fraction = fileFraction, let fileTotal {
            line += " · \(Int(fraction * 100))% of \(Self.bytes(fileTotal))"
        } else if fileDone > 0 {
            line += " · \(Self.bytes(fileDone))"
        }
        return line
    }

    static func bytes(_ count: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    /// Starting a new file, so the byte counters restart with it.
    func beginFile(named name: String, size: UInt64?) {
        currentName = name
        fileDone = 0
        fileTotal = size
        lastProgressPublish = .distantPast
    }
    @Published var prompt: Prompt?
    /// Set while a sync is waiting for the user to confirm the plan.
    @Published var syncConfirmation: SyncConfirmation?
    /// Shown when the run ends: what moved, what was skipped.
    @Published var summary: String?
    @Published var errorMessage: String?
    /// Ticked when a pane's contents may have changed, so the views reload.
    @Published var finishedRun = 0

    struct SyncConfirmation: Identifiable {
        let id = UUID()
        let direction: TransferDirection
        let summary: String
        let jobs: [TransferJob]
        let directoriesToCreate: [String]
    }

    private var plan: TransferPlan?
    private var task: Task<Void, Never>?
    private var answered: CheckedContinuation<TransferAnswer, Never>?

    func cancel() {
        task?.cancel()
        // A run waiting on the prompt is not inside the task's cancellation
        // path, so the pending question has to be released too.
        resume(.cancel)
    }

    func answer(_ answer: TransferAnswer) {
        prompt = nil
        resume(answer)
    }

    private func resume(_ answer: TransferAnswer) {
        guard let continuation = answered else { return }
        answered = nil
        continuation.resume(returning: answer)
    }

    /// Move `jobs` from `source` to `destination`, asking before overwriting.
    func run(jobs: [TransferJob], direction: TransferDirection,
             from source: RemoteFileService, to destination: RemoteFileService,
             existingAtDestination: Set<String>) {
        guard !running, !jobs.isEmpty else { return }
        let plan = TransferPlan(jobs: jobs, existingAtDestination: existingAtDestination)
        self.plan = plan
        running = true
        completed = 0
        total = jobs.count
        summary = nil
        errorMessage = nil

        task = Task { [weak self] in
            guard let self else { return }
            var moved = 0
            while true {
                if Task.isCancelled { break }
                let step = plan.nextStep()
                switch step {
                case .finished:
                    self.finish(moved: moved, skipped: plan.skipped.count,
                                cancelled: plan.cancelled)
                    return
                case .ask(let job):
                    let remaining = max(0, plan.jobs.count - self.completed - 1)
                    let answer = await self.ask(job: job, direction: direction,
                                                remaining: remaining)
                    plan.answer(answer)
                case .transfer(let job):
                    self.currentName = job.name
                    do {
                        try await self.move(job, direction: direction,
                                            from: source, to: destination)
                        moved += 1
                    } catch is CancellationError {
                        self.finish(moved: moved, skipped: plan.skipped.count, cancelled: true)
                        return
                    } catch {
                        // One bad file must not abandon the rest of the queue;
                        // the summary reports it at the end.
                        self.errorMessage = "\(job.name): \(error.localizedDescription)"
                    }
                    self.completed += 1
                }
            }
            self.finish(moved: moved, skipped: plan.skipped.count, cancelled: true)
        }
    }

    // MARK: - Sync

    /// Work out what a one-way sync would copy, then ask before doing it.
    ///
    /// Walks both trees rather than only the visible folder: "sync this folder
    /// to that one" that ignored subfolders would be a trap. Nothing is ever
    /// deleted at the destination.
    func prepareSync(direction: TransferDirection,
                     from source: RemoteFileService, sourceRoot: String,
                     to destination: RemoteFileService, destinationRoot: String) {
        guard !running else { return }
        running = true
        currentName = "Comparing…"
        summary = nil
        errorMessage = nil
        Task {
            do {
                var jobs: [TransferJob] = []
                var directories: [String] = []
                var replacingNewer = 0
                var unchanged = 0
                var conflicts = 0
                var pending: [(String, String)] = [(sourceRoot, destinationRoot)]
                // Depth guard: a symlink loop on the server would otherwise
                // walk forever. Symlinks are skipped, but a bad listing should
                // not be able to hang the app either.
                var visited = 0

                while let (from, to) = pending.first {
                    pending.removeFirst()
                    visited += 1
                    if visited > 500 { break }
                    let sourceItems = try await source.list(from)
                    // A folder that does not exist yet lists as empty rather
                    // than failing the whole sync.
                    let destinationItems = (try? await destination.list(to)) ?? []
                    let comparison = SyncPlanner.compare(source: sourceItems,
                                                         destination: destinationItems)
                    replacingNewer += comparison.replacingNewer.count
                    unchanged += comparison.unchangedFiles.count
                    conflicts += comparison.typeConflicts.count

                    for file in comparison.filesToCopy {
                        jobs.append(TransferJob(
                            name: file.name,
                            sourcePath: FTPProtocol.join(from, file.name),
                            destinationPath: FTPProtocol.join(to, file.name),
                            isDirectory: false, size: file.size))
                    }
                    for folder in comparison.directoriesToCopyWhole {
                        jobs.append(TransferJob(
                            name: folder.name,
                            sourcePath: FTPProtocol.join(from, folder.name),
                            destinationPath: FTPProtocol.join(to, folder.name),
                            isDirectory: true))
                    }
                    for folder in comparison.directoriesToDescend {
                        let child = FTPProtocol.join(to, folder.name)
                        directories.append(child)
                        pending.append((FTPProtocol.join(from, folder.name), child))
                    }
                }

                self.running = false
                self.currentName = ""
                guard !jobs.isEmpty else {
                    self.summary = "Already in sync"
                        + (unchanged > 0 ? " — \(unchanged) files match" : "") + "."
                    return
                }
                var text = "\(jobs.filter { !$0.isDirectory }.count) files, "
                    + "\(jobs.filter(\.isDirectory).count) folders."
                if replacingNewer > 0 {
                    text += " \(replacingNewer) would replace a NEWER copy at the destination."
                }
                if conflicts > 0 {
                    text += " \(conflicts) skipped (a file on one side, a folder on the other)."
                }
                if unchanged > 0 { text += " \(unchanged) already up to date." }
                self.syncConfirmation = SyncConfirmation(
                    direction: direction, summary: text, jobs: jobs,
                    directoriesToCreate: directories)
            } catch {
                self.running = false
                self.currentName = ""
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Go ahead with a confirmed sync. Everything in the plan is already known
    /// to need copying, so there is no per-file overwrite question.
    func runSync(_ confirmation: SyncConfirmation,
                 from source: RemoteFileService, to destination: RemoteFileService) {
        syncConfirmation = nil
        let plan = TransferPlan(jobs: confirmation.jobs, existingAtDestination: [])
        self.plan = plan
        running = true
        completed = 0
        total = confirmation.jobs.count
        summary = nil
        errorMessage = nil

        task = Task { [weak self] in
            guard let self else { return }
            // Intermediate folders first, or a file lands in a directory the
            // destination does not have yet.
            for directory in confirmation.directoriesToCreate {
                try? await destination.mkdir(directory)
            }
            var moved = 0
            while true {
                if Task.isCancelled { break }
                switch plan.nextStep() {
                case .finished:
                    self.finish(moved: moved, skipped: 0, cancelled: false)
                    return
                case .ask:
                    // Cannot happen: the plan was built with no conflicts.
                    plan.answer(.overwrite)
                case .transfer(let job):
                    self.currentName = job.name
                    do {
                        try await self.move(job, direction: confirmation.direction,
                                            from: source, to: destination)
                        moved += 1
                    } catch is CancellationError {
                        self.finish(moved: moved, skipped: 0, cancelled: true)
                        return
                    } catch {
                        self.errorMessage = "\(job.name): \(error.localizedDescription)"
                    }
                    self.completed += 1
                }
            }
            self.finish(moved: moved, skipped: 0, cancelled: true)
        }
    }

    private func ask(job: TransferJob, direction: TransferDirection,
                     remaining: Int) async -> TransferAnswer {
        await withCheckedContinuation { continuation in
            answered = continuation
            prompt = Prompt(job: job, direction: direction, remaining: remaining)
        }
    }

    private func move(_ job: TransferJob, direction: TransferDirection,
                      from source: RemoteFileService,
                      to destination: RemoteFileService) async throws {
        // One side is always this Mac, so every transfer is "read from the
        // remote into a local path" or "write a local path to the remote" —
        // there is no server-to-server case to handle.
        // A folder reports per-file, so its bytes are for whichever file is
        // moving; a single file reports its own. Either way the panel finally
        // has something to draw.
        let onFile: @Sendable (String, UInt64, UInt64?) -> Void = { [weak self] name, done, total in
            Task { @MainActor in
                guard let self else { return }
                if name != self.currentName { self.beginFile(named: name, size: total) }
                self.reportProgress(done: done, total: total)
            }
        }
        let onBytes: @Sendable (UInt64, UInt64?) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.reportProgress(done: done, total: total) }
        }

        switch direction {
        case .upload:
            let local = URL(fileURLWithPath: job.sourcePath)
            if job.isDirectory {
                await MainActor.run { self.beginFile(named: job.name, size: nil) }
                try await destination.uploadDirectory(localURL: local,
                                                      to: job.destinationPath, progress: onFile)
            } else {
                // The job carries the size when the plan knew it; a file
                // picked some other way is measured here. NOT localTreeSize —
                // that walks a directory and returns nil for a plain file,
                // which would have left every single-file upload without a
                // bar, the exact case being fixed.
                let size = job.size > 0
                    ? job.size
                    : (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .flatMap { $0.map(UInt64.init) }
                await MainActor.run { self.beginFile(named: job.name, size: size) }
                try await destination.upload(localURL: local,
                                             to: job.destinationPath, progress: onBytes)
            }
        case .download:
            let local = URL(fileURLWithPath: job.destinationPath)
            if job.isDirectory {
                await MainActor.run { self.beginFile(named: job.name, size: nil) }
                try await source.downloadDirectory(remotePath: job.sourcePath,
                                                   to: local, progress: onFile)
            } else {
                await MainActor.run { self.beginFile(named: job.name, size: job.size) }
                try await source.download(remotePath: job.sourcePath,
                                          to: local, progress: onBytes)
            }
        }
    }

    private func finish(moved: Int, skipped: Int, cancelled: Bool) {
        running = false
        currentName = ""
        prompt = nil
        plan = nil
        var parts: [String] = ["\(moved) transferred"]
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if cancelled { parts.append("cancelled") }
        summary = parts.joined(separator: ", ")
        finishedRun += 1
    }
}

// MARK: - Views

struct TransferPanelView: View {
    @ObservedObject var local: TransferPaneModel
    @ObservedObject var remote: TransferPaneModel
    @ObservedObject var controller: TransferController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TransferPaneView(model: local)
                Divider()
                middleButtons
                    .frame(width: 78)
                Divider()
                TransferPaneView(model: remote)
            }
            Divider()
            statusBar
        }
        .onAppear {
            local.start()
            remote.start()
        }
        .onChange(of: controller.finishedRun) { _ in
            local.refresh()
            remote.refresh()
        }
        .alert("Replace \(controller.prompt?.job.isDirectory == true ? "folder" : "file")?",
               isPresented: promptShowing, presenting: controller.prompt) { prompt in
            // Five answers, so this uses the multi-button alert rather than the
            // two-button `Alert` type. "…All" covers every remaining conflict
            // in this run; the plain answers cover just this file.
            Button("Replace") { controller.answer(.overwrite) }
            Button("Replace All") { controller.answer(.overwriteAll) }
            Button("Skip") { controller.answer(.skip) }
            Button("Skip All") { controller.answer(.skipAll) }
            // Also what Esc does, so dismissing the alert can never leave the
            // transfer waiting for an answer that is not coming.
            Button("Cancel", role: .cancel) { controller.answer(.cancel) }
        } message: { prompt in
            Text(promptMessage(prompt))
        }
        .alert("Sync \(controller.syncConfirmation?.direction == .download ? "to this Mac" : "to the server")?",
               isPresented: syncShowing, presenting: controller.syncConfirmation) { confirmation in
            Button("Sync") {
                guard let localService = local.service,
                      let remoteService = remote.service else { return }
                if confirmation.direction == .upload {
                    controller.runSync(confirmation, from: localService, to: remoteService)
                } else {
                    controller.runSync(confirmation, from: remoteService, to: localService)
                }
            }
            Button("Cancel", role: .cancel) { controller.syncConfirmation = nil }
        } message: { confirmation in
            Text(confirmation.summary)
        }
    }

    private var syncShowing: Binding<Bool> {
        Binding(get: { controller.syncConfirmation != nil },
                set: { if !$0 { controller.syncConfirmation = nil } })
    }

    private var middleButtons: some View {
        VStack(spacing: 14) {
            Spacer()
            Button {
                startUpload()
            } label: {
                Label("Upload", systemImage: "arrow.right.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .disabled(local.selection.isEmpty || controller.running || remote.state != .ready)
            .help("Copy the selected items to the server")

            Button {
                startDownload()
            } label: {
                Label("Download", systemImage: "arrow.left.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .disabled(remote.selection.isEmpty || controller.running || local.state != .ready)
            .help("Copy the selected items to this Mac")

            Divider().frame(width: 40)

            // Sync ignores the selection: it compares the two folders and
            // copies whatever is missing or out of date, recursively.
            Button { startSync(.upload) } label: {
                Label("Sync to server", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .disabled(controller.running || local.state != .ready || remote.state != .ready)
            .help("Sync this Mac's folder to the server: copy anything missing or newer. "
                  + "Nothing is deleted.")

            Button { startSync(.download) } label: {
                Label("Sync to this Mac",
                      systemImage: "arrow.trianglehead.counterclockwise.rotate.90")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .disabled(controller.running || local.state != .ready || remote.state != .ready)
            .help("Sync the server's folder to this Mac: copy anything missing or newer. "
                  + "Nothing is deleted.")
            Spacer()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if controller.running {
                // Determinate whenever the size is known, which is now the
                // usual case: a spinner beside "(1 of 1)" told you a large
                // download had started and nothing else for as long as it ran.
                if let fraction = controller.fileFraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(controller.progressLine)
                    .lineLimit(1)
                    .monospacedDigit()
                Button("Cancel") { controller.cancel() }
                    .controlSize(.small)
            } else if let summary = controller.summary {
                Image(systemName: "checkmark.circle")
                Text(summary)
            } else {
                Text("Select files, then use the arrows to copy them.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Driven by the controller's prompt, but writable so the alert can close
    /// itself; the answer buttons are what actually clears it.
    private var promptShowing: Binding<Bool> {
        Binding(get: { controller.prompt != nil },
                set: { if !$0 { controller.answer(.cancel) } })
    }

    private func promptMessage(_ prompt: TransferController.Prompt) -> String {
        let place = prompt.direction == .upload ? "on the server" : "on this Mac"
        let name = prompt.job.name
        guard prompt.remaining > 0 else {
            return "\"\(name)\" already exists \(place)."
        }
        let others = prompt.remaining == 1 ? "1 more item" : "\(prompt.remaining) more items"
        return "\"\(name)\" already exists \(place). "
            + "\(others) still to go — \"Replace All\" or \"Skip All\" answers for all of them."
    }

    private func startSync(_ direction: TransferDirection) {
        guard let localService = local.service, let remoteService = remote.service else { return }
        switch direction {
        case .upload:
            controller.prepareSync(direction: .upload,
                                   from: localService, sourceRoot: local.path,
                                   to: remoteService, destinationRoot: remote.path)
        case .download:
            controller.prepareSync(direction: .download,
                                   from: remoteService, sourceRoot: remote.path,
                                   to: localService, destinationRoot: local.path)
        }
    }

    private func startUpload() {
        let jobs = TransferPlanner.jobs(selectedNames: local.selection, from: local.items,
                                        sourceDirectory: local.path,
                                        destinationDirectory: remote.path)
        guard let source = local.service, let destination = remote.service else { return }
        controller.run(jobs: jobs, direction: .upload, from: source, to: destination,
                       existingAtDestination: Set(remote.items.map(\.name)))
    }

    private func startDownload() {
        let jobs = TransferPlanner.jobs(selectedNames: remote.selection, from: remote.items,
                                        sourceDirectory: remote.path,
                                        destinationDirectory: local.path)
        guard let source = remote.service, let destination = local.service else { return }
        controller.run(jobs: jobs, direction: .download, from: source, to: destination,
                       existingAtDestination: Set(local.items.map(\.name)))
    }
}

struct TransferPaneView: View {
    @ObservedObject var model: TransferPaneModel
    @State private var renameTarget: SFTPItem?
    @State private var renameText = ""
    @State private var deleteTargets: [SFTPItem] = []

    /// Short and fixed-width-ish: the column is narrow and every row has one.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        ), presenting: renameTarget) { item in
            TextField("New name", text: $renameText)
            Button("Rename") {
                model.rename(item, to: renameText)
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: { item in
            Text("Rename \"\(item.name)\".")
        }
        .alert(deleteTitle, isPresented: Binding(
            get: { !deleteTargets.isEmpty },
            set: { if !$0 { deleteTargets = [] } }
        )) {
            Button("Delete", role: .destructive) {
                model.delete(deleteTargets)
                deleteTargets = []
            }
            Button("Cancel", role: .cancel) { deleteTargets = [] }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteTitle: String {
        guard let first = deleteTargets.first else { return "Delete" }
        return deleteTargets.count == 1
            ? "Delete \"\(first.name)\"?"
            : "Delete \(deleteTargets.count) items?"
    }

    /// Says plainly what is about to happen, because the two sides differ:
    /// this Mac has a Trash to fish things back out of, and a server does not.
    private var deleteMessage: String {
        let folders = deleteTargets.filter(\.isDirectory).count
        var text = model.isLocal
            ? "They will be moved to the Trash."
            : "This cannot be undone — there is no trash on the server."
        if folders > 0 && !model.isLocal {
            text += folders == 1
                ? " The folder and everything inside it will be removed."
                : " The folders and everything inside them will be removed."
        }
        return text
    }

    private var header: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: model.isLocal ? "laptopcomputer" : "server.rack")
                Text(model.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !model.selection.isEmpty {
                    Text("\(model.selection.count) selected")
                        .foregroundStyle(.secondary)
                }
                sortMenu
            }
            .font(.callout.weight(.medium))
            HStack(spacing: 6) {
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .help("Parent folder")
                    .disabled(model.path == "/" || model.state != .ready)
                TextField("Path", text: $model.pathField)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { model.submitPathField() }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .disabled(model.state != .ready)
            }
        }
        .padding(8)
    }

    /// Sort control. The current key is ticked and the arrow shows the
    /// direction, so the menu says what the list is doing without opening it.
    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $model.sortKey) {
                ForEach(FileSortKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Order", selection: $model.ascending) {
                Text(model.sortKey == .name || model.sortKey == .kind
                     ? "A to Z" : "Smallest / oldest first").tag(true)
                Text(model.sortKey == .name || model.sortKey == .kind
                     ? "Z to A" : "Largest / newest first").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: model.ascending
                  ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort by \(model.sortKey.displayName)")
        .disabled(model.state != .ready)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .connecting:
            VStack { ProgressView("Connecting…") }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.title)
                Text(message).multilineTextAlignment(.center).padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            list
        }
    }

    private var list: some View {
        // A real NSTableView: single-click selection, ⌘/⇧ multi-select,
        // double-click to open and a context menu all work together there,
        // which no arrangement of SwiftUI gestures on a List row can manage.
        TransferFileTable(
            model: model,
            onRename: { item in
                renameTarget = item
                renameText = item.name
            },
            onDelete: { items in
                deleteTargets = items
            })
    }
}

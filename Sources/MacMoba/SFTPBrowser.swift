// MobaXterm-style remote file browser panel: one connection per open panel,
// sharing the tab's session credentials.
//
// The transport is whatever `RemoteFileService` the session needs — SFTP for an
// SSH session, FTP for an FTP one. Everything below (transfers, drag and drop,
// edit-locally, recursive delete) is written against that protocol, so both
// get the same panel rather than a second copy of it.

import AppKit
import MacMobaCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SFTPBrowserModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    let config: SessionConfig
    /// The bastion this session is reached through, if any. The terminal has
    /// always honoured it; the file browser must too, or it dials a host the
    /// network cannot reach and sits on "Connecting…".
    let jumps: [SessionConfig]
    let hostKeys: HostKeyVerification?
    @Published var state: State = .connecting
    @Published var path = "/"
    @Published var pathField = "/"
    @Published var items: [SFTPItem] = []
    @Published var selection: String?
    @Published var busy = false
    @Published var transfers: [SFTPTransfer] = []
    @Published var errorMessage: String?

    private var client: RemoteFileService?
    /// Same sort choice as the transfer panes, and the same stored preference:
    /// one setting for "how I like to read a directory".
    @Published var sortKey: FileSortKey {
        didSet {
            guard sortKey != oldValue else { return }
            ascending = !sortKey.prefersDescending
            UserDefaults.standard.set(sortKey.rawValue, forKey: "transferSortKey")
            resort()
        }
    }
    @Published var ascending: Bool {
        didSet {
            guard ascending != oldValue else { return }
            UserDefaults.standard.set(ascending, forKey: "transferSortAscending")
            resort()
        }
    }
    private var unsorted: [SFTPItem] = []

    /// Show dotfiles. Off by default, matching `ls` and every file browser; the
    /// preference is remembered.
    @Published var showHidden: Bool =
        UserDefaults.standard.bool(forKey: "sftpShowHidden") {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "sftpShowHidden")
            resort()
        }
    }

    /// Whether this connection can change permissions (SFTP yes, plain FTP no) —
    /// used to hide the menu item rather than offer one that always fails.
    var supportsPermissions: Bool { client?.supportsPermissions ?? false }

    private func resort() {
        let visible = showHidden
            ? unsorted
            : unsorted.filter { $0.name == ".." || !$0.name.hasPrefix(".") }
        items = FileSort.sort(visible, by: sortKey, ascending: ascending)
    }

    /// chmod, then refresh so the new mode shows.
    func setPermissions(_ item: SFTPItem, mode: UInt32) {
        guard let client else { return }
        let target = join(path, item.name)
        Task {
            do {
                try await client.setPermissions(target, mode: mode)
                await load(path)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    /// Preview a file with Quick Look: download it to a temp copy, then hand
    /// that to `qlmanage -p` (the same preview the spacebar gives in Finder).
    func quickLook(_ item: SFTPItem) {
        guard let client, !item.isDirectory else { return }
        let remote = join(path, item.name)
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmoba-ql-\(UUID().uuidString)")
            .appendingPathComponent(item.name)
        busy = true
        Task {
            defer { busy = false }
            do {
                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await client.download(remotePath: remote, to: localURL, progress: nil)
                QuickLook.preview(localURL)
            } catch {
                errorMessage = "Could not preview \(item.name): \(error)"
            }
        }
    }

    /// remotePath -> local copy being edited (MobaXterm-style "edit locally").
    final class EditSession {
        let remotePath: String
        let localURL: URL
        var lastModified: Date
        var uploading = false

        init(remotePath: String, localURL: URL, lastModified: Date) {
            self.remotePath = remotePath
            self.localURL = localURL
            self.lastModified = lastModified
        }
    }

    @Published private(set) var editSessions: [String: EditSession] = [:]
    private var editWatchTimer: Timer?

    init(config: SessionConfig, jumps: [SessionConfig] = [],
         hostKeys: HostKeyVerification? = nil) {
        self.config = config
        self.jumps = jumps
        self.hostKeys = hostKeys
        let stored = UserDefaults.standard.string(forKey: "transferSortKey")
        let key = stored.flatMap(FileSortKey.init(rawValue:)) ?? .name
        self.sortKey = key
        self.ascending = UserDefaults.standard.object(forKey: "transferSortAscending") as? Bool
            ?? !key.prefersDescending
    }

    func start() {
        guard client == nil else { return }
        state = .connecting
        Task {
            do {
                let client: RemoteFileService = config.sessionKind == .ftp
                    ? try await FTPClient.connect(config: try await SecretResolver.resolve(session: config))
                    : try await SFTPClient.connect(
                        config: try await SecretResolver.resolve(session: config),
                        via: try await SecretResolver.resolve(sessions: jumps),
                        hostKeys: hostKeys)
                self.client = client
                let home = try await client.realpath(".")
                self.state = .ready
                await load(home)
            } catch {
                self.state = .failed("\(error)")
            }
        }
    }

    func close() {
        editWatchTimer?.invalidate()
        editWatchTimer = nil
        editSessions.removeAll()
        for transfer in transfers where transfer.isRunning { transfer.cancel() }
        // Detached from this call: closing an FTP session sends QUIT, and the
        // panel is usually being torn down from a synchronous UI path that
        // cannot wait for a round trip.
        if let client {
            Task { await client.close() }
        }
        client = nil
    }

    // MARK: - Edit locally (download → open editor → auto re-upload on save)

    /// Which app opens edited files: the user's chosen editor (persisted),
    /// else the system's plain-text editor. Never the per-file-type default —
    /// that opens .sh/.conf files in terminal apps instead of an editor.
    private func editorAppURL() -> URL? {
        if let path = UserDefaults.standard.string(forKey: "sftpEditorPath"),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
    }

    private func openInEditor(_ url: URL) {
        if let editor = editorAppURL() {
            NSWorkspace.shared.open([url], withApplicationAt: editor,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// "Edit With…": pick an editor app; remembered for all future edits.
    func chooseEditorAndEdit(_ item: SFTPItem) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Editor"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        UserDefaults.standard.set(app.path, forKey: "sftpEditorPath")
        editLocally(item)
    }

    func editLocally(_ item: SFTPItem) {
        guard let client, !item.isDirectory else { return }
        let remote = join(path, item.name)
        if let existing = editSessions[remote] {
            openInEditor(existing.localURL)
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmoba-edit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(item.name)

        startTransfer(.download, name: item.name, total: item.size) { [weak self] transfer in
            try await client.download(remotePath: remote, to: local) { done, total in
                Task { @MainActor in transfer.updateFile(done: done, total: total) }
            }
            await MainActor.run {
                guard let self else { return }
                let attrs = try? FileManager.default.attributesOfItem(atPath: local.path)
                let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
                self.editSessions[remote] = EditSession(remotePath: remote, localURL: local,
                                                        lastModified: mtime)
                self.ensureEditWatcher()
                self.openInEditor(local)
            }
        }
    }

    func stopEditing(_ remotePath: String) {
        editSessions[remotePath] = nil
        if editSessions.isEmpty {
            editWatchTimer?.invalidate()
            editWatchTimer = nil
        }
    }

    private func ensureEditWatcher() {
        guard editWatchTimer == nil else { return }
        // Poll mtimes: robust against editors that atomic-save (rename),
        // which breaks fd-based DispatchSource watches.
        editWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEditedFiles() }
        }
    }

    private func checkEditedFiles() {
        guard let client else { return }
        for (remote, session) in editSessions {
            guard !session.uploading,
                  let mtime = (try? FileManager.default.attributesOfItem(atPath: session.localURL.path))?[.modificationDate] as? Date,
                  mtime > session.lastModified else { continue }
            session.uploading = true
            session.lastModified = mtime
            let name = session.localURL.lastPathComponent
            startTransfer(.upload, name: name, total: nil) { transfer in
                defer { Task { @MainActor in session.uploading = false } }
                try await client.upload(localURL: session.localURL, to: remote) { done, total in
                    Task { @MainActor in transfer.updateFile(done: done, total: total) }
                }
            }
        }
    }

    // MARK: - Transfer bookkeeping

    /// Run a transfer in its own Task, tracked in `transfers`. Transfers are
    /// independent (SFTP multiplexes by request id), so several may run at once.
    @discardableResult
    private func startTransfer(
        _ kind: SFTPTransfer.Kind,
        name: String,
        total: UInt64?,
        body: @escaping (SFTPTransfer) async throws -> Void
    ) -> SFTPTransfer {
        let transfer = SFTPTransfer(kind: kind, name: name, total: total)
        transfers.append(transfer)
        transfer.task = Task {
            do {
                try await body(transfer)
                transfer.markDone()
            } catch is CancellationError {
                transfer.status = .cancelled
            } catch {
                transfer.underlyingError = error
                transfer.status = .failed("\(error)")
            }
            transfer.task = nil
            await load(path)
        }
        return transfer
    }

    func clearFinishedTransfers() {
        transfers.removeAll { !$0.isRunning }
    }

    func retry() {
        close()
        state = .connecting
        client = nil
        start()
    }

    // MARK: - Navigation

    func load(_ newPath: String) async {
        guard let client else { return }
        busy = true
        defer { busy = false }
        do {
            let resolved = try await client.realpath(newPath)
            let listed = try await client.list(resolved)
            path = resolved
            pathField = resolved
            unsorted = listed
            resort()
            selection = nil
        } catch {
            errorMessage = "\(error)"
            pathField = path
        }
    }

    func openItem(_ item: SFTPItem) {
        guard item.isDirectory || item.isSymlink else { return }
        Task { await load(join(path, item.name)) }
    }

    func goUp() {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        Task { await load(parent.isEmpty ? "/" : parent) }
    }

    func refresh() {
        Task { await load(path) }
    }

    func submitPathField() {
        Task { await load(pathField) }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    // MARK: - File operations

    func makeDirectory(named name: String) {
        guard let client, !name.isEmpty else { return }
        run { await self.wrap("Create folder failed") { try await client.mkdir(self.join(self.path, name)) } }
    }

    func rename(_ item: SFTPItem, to newName: String) {
        guard let client, !newName.isEmpty, newName != item.name else { return }
        run {
            await self.wrap("Rename failed") {
                try await client.rename(self.join(self.path, item.name),
                                        to: self.join(self.path, newName))
            }
        }
    }

    func delete(_ item: SFTPItem) {
        guard let client else { return }
        run {
            await self.wrap("Delete failed") {
                if item.isDirectory {
                    try await client.removeDirectoryRecursively(self.join(self.path, item.name))
                } else {
                    try await client.removeFile(self.join(self.path, item.name))
                }
            }
        }
    }

    func download(_ item: SFTPItem) {
        guard let client else { return }
        let remote = join(path, item.name)
        if item.isDirectory {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Download Here"
            guard panel.runModal() == .OK, let destDir = panel.url else { return }
            let dest = destDir.appendingPathComponent(item.name)
            startTransfer(.download, name: item.name, total: nil) { transfer in
                // Size the tree first, so the bar means something. Best
                // effort: a scan that fails leaves the transfer indeterminate,
                // which is how it always behaved, rather than failing a copy
                // over a progress figure.
                if let total = try? await client.totalSize(ofDirectory: remote) {
                    await MainActor.run { transfer.setTotal(total) }
                }
                try await client.downloadDirectory(remotePath: remote, to: dest) { file, done, _ in
                    Task { @MainActor in transfer.updateTree(file: file, fileDone: done) }
                }
            }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = item.name
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            startTransfer(.download, name: item.name, total: item.size) { transfer in
                try await client.download(remotePath: remote, to: dest) { done, total in
                    Task { @MainActor in transfer.updateFile(done: done, total: total) }
                }
            }
        }
    }

    /// Bytes of a local folder, for sizing an upload before it starts.
    ///
    /// Symlinks are skipped to match what the upload sends, and any file that
    /// cannot be measured is simply left out — a total that is slightly low
    /// makes the bar finish early, which is better than refusing to show one.
    static func localTreeSize(_ url: URL) -> UInt64? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return nil }
        var total: UInt64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += UInt64(size)
        }
        return total > 0 ? total : nil
    }

    // MARK: - In-panel drag (move)

    func remotePathForDrag(_ item: SFTPItem) -> String {
        join(path, item.name)
    }

    /// Backing for drag-out to Finder: writes the file, or a whole folder
    /// tree, to the URL the file promise hands us.
    func downloadForDrag(_ item: SFTPItem, to url: URL) async throws {
        guard let client else { throw SFTPError.closed }
        let remote = join(path, item.name)
        let transfer = startTransfer(
            .download, name: item.name,
            total: item.isDirectory ? nil : item.size
        ) { transfer in
            if item.isDirectory {
                // Size the tree first, so the bar means something. Best
                // effort: a scan that fails leaves the transfer indeterminate,
                // which is how it always behaved, rather than failing a copy
                // over a progress figure.
                if let total = try? await client.totalSize(ofDirectory: remote) {
                    await MainActor.run { transfer.setTotal(total) }
                }
                try await client.downloadDirectory(remotePath: remote, to: url) { file, done, _ in
                    Task { @MainActor in transfer.updateTree(file: file, fileDone: done) }
                }
            } else {
                try await client.download(remotePath: remote, to: url) { done, total in
                    Task { @MainActor in transfer.updateFile(done: done, total: total) }
                }
            }
        }
        await transfer.task?.value
        switch transfer.status {
        case .cancelled: throw CancellationError()
        case .failed: throw transfer.underlyingError ?? SFTPError.closed
        default: return
        }
    }

    private var dragged: SFTPDraggedItem?

    func beginDrag(_ item: SFTPItem) {
        dragged = SFTPDraggedItem(item: item, sourceDirectory: path)
    }

    /// Returns the in-flight drag exactly once, so a Finder drop that follows
    /// isn't mistaken for an internal move.
    func consumeDraggedItem() -> SFTPDraggedItem? {
        defer { dragged = nil }
        guard let dragged, dragged.isFresh else { return nil }
        return dragged
    }

    /// Move an item into a folder with a server-side rename.
    func moveItem(_ dragged: SFTPDraggedItem, intoFolder folder: SFTPItem) {
        guard let client else { return }
        let source = dragged.sourceDirectory == "/"
            ? "/" + dragged.item.name
            : dragged.sourceDirectory + "/" + dragged.item.name
        let destDir = join(path, folder.name)
        let dest = destDir == "/" ? "/" + dragged.item.name : destDir + "/" + dragged.item.name
        // no-op / self / own-subtree guards
        guard dest != source,
              !(dragged.item.isDirectory && (destDir == source || destDir.hasPrefix(source + "/")))
        else { return }
        run {
            await self.wrap("Move failed") {
                try await client.rename(source, to: dest)
            }
        }
    }

    /// Backing for drop-in from Finder: uploads files and folders into
    /// `destination` (defaults to the current directory).
    func uploadItems(_ urls: [URL], destination: String? = nil) {
        guard let client, !urls.isEmpty else { return }
        let destDir = destination ?? path
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let remote = join(destDir, url.lastPathComponent)
            if isDir.boolValue {
                startTransfer(.upload, name: url.lastPathComponent, total: nil) { transfer in
                    // Local tree, so the size costs no round trips.
                    if let total = Self.localTreeSize(url) {
                        await MainActor.run { transfer.setTotal(total) }
                    }
                    try await client.uploadDirectory(localURL: url, to: remote) { file, done, _ in
                        Task { @MainActor in transfer.updateTree(file: file, fileDone: done) }
                    }
                }
            } else {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
                startTransfer(.upload, name: url.lastPathComponent, total: size) { transfer in
                    try await client.upload(localURL: url, to: remote) { done, total in
                        Task { @MainActor in transfer.updateFile(done: done, total: total) }
                    }
                }
            }
        }
    }

    func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        uploadItems(panel.urls)
    }

    // MARK: - Helpers

    private func run(_ body: @escaping () async -> Void) {
        Task {
            busy = true
            await body()
            busy = false
            await load(path)
        }
    }

    private func wrap(_ what: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            errorMessage = "\(what): \(error)"
        }
    }
}

// MARK: - View

struct SFTPBrowserView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: SFTPBrowserModel
    /// "user@host" when the tab spans several machines; nil when there is only
    /// one and the question cannot arise.
    var hostLabel: String?
    @State private var renameTarget: SFTPItem?
    @State private var renameText = ""
    @State private var permissionsTarget: SFTPItem?
    @State private var permissionsText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var dropTargeted = false
    @State private var dropFolderTarget: String?
    @State private var deleteTarget: SFTPItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !model.transfers.isEmpty {
                Divider()
                SFTPTransfersView(model: model)
            }
        }
        .frame(minWidth: 240, idealWidth: 300)
        .onAppear { model.start() }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let item = renameTarget { model.rename(item, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                model.makeDirectory(named: newFolderName)
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Permissions for “\(permissionsTarget?.name ?? "")”", isPresented: Binding(
            get: { permissionsTarget != nil },
            set: { if !$0 { permissionsTarget = nil } }
        )) {
            TextField("Octal (e.g. 644)", text: $permissionsText)
            Button("Apply") {
                if let item = permissionsTarget, let mode = FileMode.parse(permissionsText) {
                    model.setPermissions(item, mode: mode)
                }
                permissionsTarget = nil
            }
            Button("Cancel", role: .cancel) { permissionsTarget = nil }
        } message: {
            Text(FileMode.parse(permissionsText).map { "\(permissionsText) = \(FileMode.symbolic($0))" }
                 ?? "Enter an octal mode like 644 or 755.")
        }
        .alert(
            "Delete \"\(deleteTarget?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let item = deleteTarget { model.delete(item) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.isDirectory == true
                 ? "The folder and everything inside it will be deleted from the server."
                 : "The file will be deleted from the server.")
        }
        // Errors are notifications, not decisions — they banner (P0-3).
        .onChange(of: model.errorMessage) { message in
            guard let message else { return }
            model.errorMessage = nil
            app.lastError = "SFTP: \(message)"
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            // Only shown when the tab holds panes on more than one machine.
            // Then the panel serves the FOCUSED pane's host, and an upload goes
            // to that one host even while broadcast input is typing into all of
            // them — so which host it is has to be on screen.
            if let host = hostLabel {
                HStack(spacing: 5) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                    Text(host).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Files and uploads go to this host only")
            }
            HStack(spacing: 8) {
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .help("Parent directory")
                    .disabled(model.path == "/" || model.state != .ready)
                TextField("Path", text: $model.pathField)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { model.submitPathField() }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .disabled(model.state != .ready)
            }
            HStack(spacing: 8) {
                Button { model.upload() } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                Button { showNewFolder = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Spacer()
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
                Toggle(isOn: $model.showHidden) {
                    Image(systemName: model.showHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .help(model.showHidden ? "Hide dotfiles" : "Show hidden files")
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .disabled(model.state != .ready)
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .connecting:
            VStack(spacing: 8) {
                ProgressView()
                Text("Connecting SFTP…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { model.retry() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            SFTPFileTable(
                model: model,
                onEdit: { model.editLocally($0) },
                onEditWith: { model.chooseEditorAndEdit($0) },
                onRename: { item in
                    renameText = item.name
                    renameTarget = item
                },
                onDelete: { deleteTarget = $0 }
            )
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty, model.state == .ready else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadFileURL(provider) { urls.append(url) }
            }
            model.uploadItems(urls)
        }
        return true
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SFTPItem) -> some View {
        if item.isDirectory {
            rowContent(item)
                .onDrop(
                    of: [.item, .fileURL],
                    isTargeted: Binding(
                        get: { dropFolderTarget == item.id },
                        set: { targeted in
                            if targeted {
                                dropFolderTarget = item.id
                            } else if dropFolderTarget == item.id {
                                dropFolderTarget = nil
                            }
                        }
                    )
                ) { handleFolderDrop($0, folder: item) }
        } else {
            rowContent(item)
        }
    }

    private func rowContent(_ item: SFTPItem) -> some View {
        HStack(spacing: 6) {
            SFTPItemIcon(item: item)
            // Click/double-click, and drag onto a folder row to move.
            HStack {
                Text(item.name)
                    .lineLimit(1)
                if isBeingEdited(item) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help("Editing locally — saves upload automatically")
                }
                Spacer()
                if !item.isDirectory {
                    Text(Self.sizeFormatter.string(fromByteCount: Int64(item.size)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onDrag {
                model.selection = item.id
                model.beginDrag(item)
                return NSItemProvider(object: item.name as NSString)
            } preview: {
                HStack(spacing: 4) {
                    SFTPItemIcon(item: item)
                    Text(item.name).font(.callout)
                }
                .padding(4)
            }
            .onTapGesture(count: 2) { model.openItem(item) }
            .onTapGesture(count: 1) { model.selection = item.id }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(rowBackground(item), in: RoundedRectangle(cornerRadius: 4))
        .contextMenu {
            if item.isDirectory {
                Button("Open") { model.openItem(item) }
            } else if isBeingEdited(item) {
                Button("Open Local Copy") { model.editLocally(item) }
                Button("Stop Watching") { model.stopEditing(remotePath(item)) }
            } else {
                Button("Quick Look") { model.quickLook(item) }
                Button("Edit Locally") { model.editLocally(item) }
                Button("Edit With…") { model.chooseEditorAndEdit(item) }
            }
            Button("Download…") { model.download(item) }
            Button("Rename…") {
                renameText = item.name
                renameTarget = item
            }
            if model.supportsPermissions {
                Button("Permissions…") {
                    permissionsText = FileMode.octalString(item.attributes.permissions ?? 0)
                    permissionsTarget = item
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { deleteTarget = item }
        }
        .help(item.longname)
    }

    private func rowBackground(_ item: SFTPItem) -> Color {
        if dropFolderTarget == item.id { return Color.accentColor.opacity(0.30) }
        if model.selection == item.id { return Color.accentColor.opacity(0.18) }
        return .clear
    }

    private func handleFolderDrop(_ providers: [NSItemProvider], folder: SFTPItem) -> Bool {
        // Internal drag: move server-side (identity comes from the model).
        if let dragged = model.consumeDraggedItem() {
            model.moveItem(dragged, intoFolder: folder)
            return true
        }
        // Finder drag: upload into this folder.
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty, model.state == .ready else { return false }
        let destination = model.remotePathForDrag(folder)
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadFileURL(provider) { urls.append(url) }
            }
            model.uploadItems(urls, destination: destination)
        }
        return true
    }

    private func remotePath(_ item: SFTPItem) -> String {
        model.path == "/" ? "/" + item.name : model.path + "/" + item.name
    }

    private func isBeingEdited(_ item: SFTPItem) -> Bool {
        model.editSessions[remotePath(item)] != nil
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}

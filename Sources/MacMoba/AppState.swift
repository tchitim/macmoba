// Shared app state: vault lifecycle, session/tunnel/macro CRUD, preferences,
// active port forwards. One instance for the whole app — the tabs each window
// shows live in WindowState.

import Foundation
import MacMobaCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let vault: Vault

    @Published var unlocked = false
    @Published var data = VaultData()
    /// MultiExec is app-wide on purpose: broadcasting to "every connected
    /// session" should not stop at a window boundary.
    /// Arranging the panes when this comes on is done by the window that owns
    /// the toolbar button (see ContentView), not here: it should tidy the
    /// window you clicked in, not every window you have open.
    @Published var broadcastInput = false
    // Both funnel into the banner queue (P0-3): every existing call site that
    // sets these now produces a non-blocking banner instead of a modal. The
    // property resets itself so the next assignment always fires didSet.
    @Published var lastError: String? {
        didSet {
            guard let message = lastError else { return }
            lastError = nil
            notify(message, isError: true)
        }
    }
    @Published var infoMessage: String? {
        didSet {
            guard let message = infoMessage else { return }
            infoMessage = nil
            notify(message)
        }
    }

    // MARK: - Banners (P0-3)
    //
    // Modal alerts are reserved for decisions (delete, overwrite, host-key
    // changes); results and errors slide in at the top of the window and get
    // out of the way on their own.

    struct AppBanner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    @Published private(set) var banner: AppBanner?
    private var bannerQueue: [AppBanner] = []
    private var bannerDismiss: DispatchWorkItem?

    /// Show a transient notification. Queued, not overwritten, so quick
    /// successive results each get read.
    func notify(_ text: String, isError: Bool = false) {
        bannerQueue.append(AppBanner(text: text, isError: isError))
        pumpBanner()
    }

    func dismissBanner() {
        bannerDismiss?.cancel()
        banner = nil
        pumpBanner()
    }

    private func pumpBanner() {
        guard banner == nil, !bannerQueue.isEmpty else { return }
        banner = bannerQueue.removeFirst()
        let work = DispatchWorkItem { [weak self] in
            self?.banner = nil
            self?.pumpBanner()
        }
        bannerDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Open windows, weakly held so a closed window deallocates. AppState is
    /// the app's own @StateObject, so it outlives all of them.
    private var windowBoxes: [WeakWindow] = []

    private struct WeakWindow {
        weak var value: WindowState?
    }

    var windows: [WindowState] {
        windowBoxes.compactMap(\.value)
    }

    func register(_ window: WindowState) {
        windowBoxes.removeAll { $0.value == nil }
        guard !windowBoxes.contains(where: { $0.value === window }) else { return }
        windowBoxes.append(WeakWindow(value: window))
    }

    /// Every tab in every window — for things that must reach the whole app,
    /// like locking the vault or restyling terminals.
    var allTabs: [SessionTab] {
        windows.flatMap(\.tabs)
    }

    /// Bring the window holding `tab` to the front with `tab` selected — the
    /// Overview's click-to-focus.
    func focus(tab: SessionTab) {
        for window in windows where window.focus(tab) {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
    }

    /// Import is a vault write, so say what will happen before doing it.
    func confirmImportSSHConfig() {
        let count = importSSHConfig()
        if count > 0 {
            infoMessage = "Imported \(count) host(s) from ~/.ssh/config into the “SSH Config” group."
        }
    }
    @Published var terminalFontSize: Double =
        UserDefaults.standard.object(forKey: "terminalFontSize") as? Double ?? 13 {
        didSet {
            UserDefaults.standard.set(terminalFontSize, forKey: "terminalFontSize")
            for tab in allTabs {
                tab.localTerminal?.applyFont(size: terminalFontSize)
                for pane in tab.panes { pane.applyFont(size: terminalFontSize) }
            }
        }
    }

    /// Ask before a macro fans out to every connected session. A macro plus
    /// MultiExec runs on the whole fleet from one keystroke, with no shell
    /// prompt in between to catch a mistake.
    @Published var confirmBroadcastMacros: Bool =
        UserDefaults.standard.object(forKey: "confirmBroadcastMacros") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(confirmBroadcastMacros, forKey: "confirmBroadcastMacros")
        }
    }

    @Published var themeID: String =
        UserDefaults.standard.string(forKey: "terminalTheme") ?? "default" {
        didSet {
            UserDefaults.standard.set(themeID, forKey: "terminalTheme")
            applyThemeToAllPanes()
        }
    }

    /// Reopen the sessions that were open when the app last quit. Default on:
    /// most people expect their workspace back, and each tab still connects the
    /// same way it always did.
    @Published var reopenSessionsOnLaunch: Bool =
        UserDefaults.standard.object(forKey: "reopenSessionsOnLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reopenSessionsOnLaunch, forKey: "reopenSessionsOnLaunch") }
    }

    /// After the Mac wakes, redial the terminal sessions that had dropped while
    /// it slept, instead of leaving them on "Connection closed — press Return".
    @Published var reconnectAfterSleep: Bool =
        UserDefaults.standard.object(forKey: "reconnectAfterSleep") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reconnectAfterSleep, forKey: "reconnectAfterSleep") }
    }

    /// "auto" follows the system appearance (P2-11); a concrete id is fixed.
    var theme: TerminalTheme {
        TerminalTheme.resolve(id: themeID, darkMode: systemIsDark)
    }

    private var systemIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Restyle open terminals when the system switches light/dark, so an
    /// "Auto" theme changes with it — scrollback intact, no reconnect.
    func startAppearanceObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.themeID == TerminalTheme.autoID else { return }
                self.objectWillChange.send()   // backgrounds read app.theme
                self.applyThemeToAllPanes()
            }
        }
    }

    func applyThemeToAllPanes() {
        let theme = self.theme
        for tab in allTabs {
            tab.localTerminal.map { theme.apply(to: $0.termView) }
            for pane in tab.panes { theme.apply(to: pane.termView) }
        }
    }

    func adjustFontSize(_ delta: Double) {
        terminalFontSize = min(32, max(8, terminalFontSize + delta))
    }

    func resetFontSize() {
        terminalFontSize = 13
    }

    // MARK: - Workspace restore

    private static let openSessionsKey = "openSessionIDs"
    private static let openLayoutKey = "openWorkspaceLayout"

    /// Remember the sessions currently open so the next launch can reopen them.
    /// Called on user-driven open/close only — never while the vault is locking,
    /// so a lock (which closes every tab) does not erase the saved workspace.
    /// Local shells and ad-hoc connections have no saved session, so their id is
    /// not in the vault and they fall out naturally.
    func saveOpenWorkspace() {
        guard unlocked else { return }
        // The arrangement, not just the list: a shell beside a remote desktop
        // came back as two unrelated tabs, and rebuilding that by hand every
        // morning is the work a session manager exists to remove.
        let layout = WorkspaceLayout(tabs: allTabs.map(\.layout))
            .restorable(available: data.sessions.map(\.id))
        UserDefaults.standard.set(layout.encoded(), forKey: Self.openLayoutKey)
        // Kept in step so an older build — or a downgrade — still finds
        // something it understands.
        UserDefaults.standard.set(layout.tabs.compactMap(\.sessionIDs.first),
                                  forKey: Self.openSessionsKey)
    }

    /// The arrangement to restore, pruned to sessions that still exist. Falls
    /// back to the flat list an older version saved.
    func restorableWorkspace() -> WorkspaceLayout {
        guard reopenSessionsOnLaunch else { return WorkspaceLayout(tabs: []) }
        let saved = WorkspaceLayout.decoded(from: UserDefaults.standard.data(forKey: Self.openLayoutKey))
            ?? WorkspaceLayout.fromSessionIDs(
                UserDefaults.standard.stringArray(forKey: Self.openSessionsKey) ?? [])
        return saved.restorable(available: data.sessions.map(\.id))
    }

    // MARK: - Sleep / wake

    /// Terminal panes that were connected when the Mac last went to sleep.
    private var connectedAtSleep: Set<UUID> = []

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        }
    }

    private func handleWillSleep() {
        guard reconnectAfterSleep else { return }
        connectedAtSleep = Set(allTabs.flatMap(\.panes)
            .filter { $0.state == .connected }.map(\.id))
    }

    private func handleDidWake() {
        guard reconnectAfterSleep, !connectedAtSleep.isEmpty else { return }
        let ids = connectedAtSleep
        connectedAtSleep = []
        // Give the network a moment to come back, and the dead sockets a moment
        // to surface as closed, before redialling only those.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            for pane in self.allTabs.flatMap(\.panes) where ids.contains(pane.id) {
                pane.reconnectAfterWake()
            }
        }
    }

    enum ActiveForward {
        case local(LocalForward)
        case remote(RemoteForward)
        case dynamic(DynamicForward)

        func stop() {
            switch self {
            case .local(let f): f.stop()
            case .remote(let f): f.stop()
            case .dynamic(let f): f.stop()
            }
        }
    }

    // tunnelId -> running forward
    @Published var activeForwards: [String: ActiveForward] = [:]

    let hostKeyVerification: HostKeyVerification
    /// The scriptability socket (cmux-style); see ControlCommands.swift.
    var controlServer: ControlServer?
    /// Reachability polling. Lives here rather than per-window: it watches the
    /// vault's sessions, which every window shares — and a menu command needs
    /// to reach it without going through a window.
    let healthMonitor = HealthMonitor()
    /// Forwards physical keys to a focused remote desktop, so the input method
    /// selected on THIS Mac cannot decide what the remote one receives, and
    /// owns the click-to-capture grab.
    let vncKeyboard = VNCKeyboardBridge()
    /// Counts what the server actually sends about the pointer, to answer why
    /// the remote cursor never changes shape.
    let vncCursorDiagnostics = VNCCursorDiagnostics()
    /// Keeps the library's own clipboard log lines, to answer which half of
    /// copy-and-paste is silent.
    let vncLogger = VNCDiagnosticLogger()

    /// One report covering both VNC puzzles, for pasting into a bug report.
    func copyVNCDiagnostics() {
        let typed = vncKeyboard.lastTypedKeyCount.map(String.init) ?? "never used"
        let text = vncCursorDiagnostics.report
            + "\n\nclipboard\n" + vncLogger.report
            + "\nkeys sent by last Paste to Remote (⌥⌘V): \(typed)"
            + "\n\nkeyboard focus\n" + vncKeyboard.focusReport
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Kept as the concrete type as well: `HostKeyVerification.store` is the
    /// protocol, which deliberately only knows how to look up and pin. Review
    /// and revocation need the store itself.
    let knownHosts: KnownHostsStore

    /// Where vault.json / known_hosts.json live. MACMOBA_DATA_DIR overrides the
    /// default location (used by UI tests, and handy for keeping the vault on
    /// an external or synced volume).
    /// nonisolated: pure computation over the environment, and the RDP
    /// certificate store needs it from the FreeRDP connection thread.
    nonisolated static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MACMOBA_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMoba", isDirectory: true)
    }

    init() {
        let dir = Self.dataDirectory
        vault = Vault(fileURL: dir.appendingPathComponent("vault.json"))
        let knownHosts = KnownHostsStore(fileURL: dir.appendingPathComponent("known_hosts.json"))
        self.knownHosts = knownHosts
        hostKeyVerification = Self.makeHostKeyVerification(
            store: knownHosts, prompter: HostKeyPrompter(store: knownHosts))
        observeSleepWake()
        startAppearanceObserver()
        startControlServer()
        vncKeyboard.install()
        vncKeyboard.copyFromRemote = { [weak self] in
            Task { await self?.copyClipboardFromRemoteDesktop() }
        }
        healthMonitor.jumpProbe = { [weak self] session in
            guard let self else { return .down(reason: "quitting") }
            return await self.probeViaJumpChain(session)
        }
    }

    var vaultExists: Bool { vault.status != .none }

    // MARK: - Vault

    func createVault(masterPassword: String, rememberForTouchID: Bool = false) {
        do {
            data = try vault.create(masterPassword: masterPassword)
            unlocked = true
            updateStoredPassword(masterPassword, remember: rememberForTouchID)
        } catch VaultError.weakPassword {
            lastError = "Master password must be at least 4 characters."
        } catch {
            lastError = "Could not create vault: \(error)"
        }
    }

    func unlockVault(masterPassword: String, rememberForTouchID: Bool = false) {
        do {
            data = try vault.unlock(masterPassword: masterPassword)
            unlocked = true
            updateStoredPassword(masterPassword, remember: rememberForTouchID)
        } catch VaultError.wrongPassword {
            lastError = "Wrong master password."
        } catch {
            lastError = "Could not unlock vault: \(error)"
        }
    }

    /// Touch ID path: authenticate, pull the password from the keychain, unlock.
    func unlockWithTouchID() {
        Task {
            do {
                let password = try await BiometricUnlock.readAfterAuthentication()
                data = try vault.unlock(masterPassword: password)
                unlocked = true
            } catch BiometricUnlockError.cancelled {
                // fall back to typing the master password
            } catch VaultError.wrongPassword {
                // stored password is stale (vault password changed) — drop it
                BiometricUnlock.delete()
                lastError = "The stored password no longer matches the vault. Enter the master password."
            } catch {
                lastError = "Touch ID unlock failed: \(error)"
            }
        }
    }

    private func updateStoredPassword(_ password: String, remember: Bool) {
        if remember {
            do {
                try BiometricUnlock.store(password)
            } catch {
                lastError = "Could not store the password in the keychain: \(error)"
            }
        } else {
            BiometricUnlock.delete()
        }
    }

    func lockVault() {
        for window in windows { window.closeAllTabs() }
        for (_, fwd) in activeForwards { fwd.stop() }
        activeForwards.removeAll()
        vault.lock()
        data = VaultData()
        unlocked = false
    }

    private func persist() {
        do { try vault.save(data) } catch { lastError = "Could not save vault: \(error)" }
    }

    // MARK: - Sessions

    func upsertSession(_ config: SessionConfig) {
        if let i = data.sessions.firstIndex(where: { $0.id == config.id }) {
            data.sessions[i] = config
        } else {
            data.sessions.append(config)
        }
        persist()
    }

    func deleteSession(_ config: SessionConfig) {
        data.sessions.removeAll { $0.id == config.id }
        let orphaned = data.tunnels.filter { $0.sessionId == config.id }
        for t in orphaned { stopTunnel(t) }
        data.tunnels.removeAll { $0.sessionId == config.id }
        persist()
    }

    // MARK: - Session groups

    /// All group names in use, sorted.
    var sessionGroups: [String] {
        Set(data.sessions.compactMap { $0.group?.isEmpty == false ? $0.group : nil }).sorted()
    }

    func sessions(inGroup group: String?) -> [SessionConfig] {
        data.sessions.filter { ($0.group?.isEmpty == false ? $0.group : nil) == group }
    }

    func setGroup(_ group: String?, for session: SessionConfig) {
        guard let i = data.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        data.sessions[i].group = group?.isEmpty == false ? group : nil
        persist()
    }

    /// Create a folder that exists before anything is in it — "New Subfolder…".
    /// Returns the path, or nil when the name is unusable.
    @discardableResult
    func createFolder(under parent: String?, name: String) -> String? {
        guard let path = GroupTree.childPath(of: parent, name: name) else { return nil }
        guard !data.folders.contains(path) else { return path }
        data.folders.append(path)
        persist()
        return path
    }

    func renameGroup(_ old: String, to new: String) {
        guard !new.isEmpty else { return }
        // Subtree-aware: renaming "P" carries "P/Linux" along ("Proj/Linux").
        for i in data.sessions.indices {
            if let g = data.sessions[i].group {
                data.sessions[i].group = GroupTree.rename(g, from: old, to: new)
            }
        }
        // Explicitly-created folders move with the subtree too, or an empty
        // subfolder would be orphaned under the old name.
        data.folders = data.folders.map { GroupTree.rename($0, from: old, to: new) }
        // Folder defaults are keyed by path — they must travel with the rename
        // or inherited credentials silently detach.
        data.groupCredentials = Dictionary(uniqueKeysWithValues:
            data.groupCredentials.map { (GroupTree.rename($0.key, from: old, to: new), $0.value) })
        persist()
    }

    /// Dissolve a folder: its sessions (and those in its subfolders) come out to
    /// the top level, and the folder — with its subfolders — stops existing.
    func disbandGroup(_ group: String) {
        for i in data.sessions.indices
        where GroupTree.contains(group, group: data.sessions[i].group) {
            data.sessions[i].group = nil
        }
        data.folders.removeAll { $0 == group || GroupTree.isDescendant($0, of: group) }
        // Folder defaults for the subtree go too, or they would silently apply
        // to a folder of the same name recreated later.
        data.groupCredentials = data.groupCredentials.filter {
            !($0.key == group || GroupTree.isDescendant($0.key, of: group))
        }
        persist()
    }

    /// Import ~/.ssh/config into the vault. Returns how many were added.
    @discardableResult
    func importSSHConfig() -> Int {
        do {
            let parsed = try SSHConfigImporter.parse(fileURL: SSHConfigImporter.defaultConfigURL)
            let new = SSHConfigImporter.sessions(from: parsed, existing: data.sessions)
            guard !new.isEmpty else {
                lastError = parsed.isEmpty
                    ? "No hosts found in ~/.ssh/config."
                    : "All \(parsed.count) host(s) in ~/.ssh/config are already in your sessions."
                return 0
            }
            data.sessions.append(contentsOf: new)
            persist()
            return new.count
        } catch {
            lastError = "Could not read ~/.ssh/config: \(error)"
            return 0
        }
    }

    /// Import sessions from an exported file (OpenSSH config, PuTTY `.reg`, or
    /// RDCMan `.rdg`), auto-detecting the format and skipping anything already
    /// saved. Returns how many were added; sets `lastError` on trouble.
    @discardableResult
    func importSessions(from url: URL) -> Int {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "Could not read \(url.lastPathComponent)."
            return 0
        }
        guard let format = SessionImporter.detect(filename: url.lastPathComponent, content: content) else {
            lastError = "\(url.lastPathComponent) is not a recognised sessions file (OpenSSH config, PuTTY .reg, or RDCMan .rdg)."
            return 0
        }
        let new = SessionImporter.parse(content, as: format, existing: data.sessions)
        guard !new.isEmpty else {
            lastError = "No new sessions found in \(url.lastPathComponent) (all already imported, or none of a supported protocol)."
            return 0
        }
        data.sessions.append(contentsOf: new)
        persist()
        return new.count
    }

    // MARK: - Macros

    func upsertMacro(_ macro: MacroConfig) {
        if let i = data.macros.firstIndex(where: { $0.id == macro.id }) {
            data.macros[i] = macro
        } else {
            data.macros.append(macro)
        }
        persist()
    }

    func deleteMacro(_ macro: MacroConfig) {
        data.macros.removeAll { $0.id == macro.id }
        persist()
    }

    func moveMacro(_ macro: MacroConfig, by offset: Int) {
        guard let i = data.macros.firstIndex(where: { $0.id == macro.id }) else { return }
        let target = i + offset
        guard data.macros.indices.contains(target) else { return }
        data.macros.swapAt(i, target)
        persist()
    }

    // MARK: - Shared credentials

    func upsertCredential(_ credential: CredentialConfig) {
        if let i = data.credentials.firstIndex(where: { $0.id == credential.id }) {
            data.credentials[i] = credential
        } else {
            data.credentials.append(credential)
        }
        persist()
    }

    /// Removing a credential leaves any session that referenced it to fall back
    /// to its own inline fields (CredentialResolver treats a missing id as
    /// custom), so there is nothing to clean up on the sessions themselves.
    func deleteCredential(_ credential: CredentialConfig) {
        data.credentials.removeAll { $0.id == credential.id }
        data.groupCredentials = data.groupCredentials.filter { $0.value != credential.id }
        persist()
    }

    /// Set (or clear, with nil) the default credential a group's sessions
    /// inherit.
    func setGroupCredential(_ credentialID: String?, for group: String) {
        if let credentialID, !credentialID.isEmpty {
            data.groupCredentials[group] = credentialID
        } else {
            data.groupCredentials[group] = nil
        }
        persist()
    }

    func groupCredentialID(for group: String) -> String? {
        data.groupCredentials[group]
    }

    // MARK: - Templates

    func upsertTemplate(_ template: SessionConfig) {
        if let i = data.templates.firstIndex(where: { $0.id == template.id }) {
            data.templates[i] = template
        } else {
            data.templates.append(template)
        }
        persist()
    }

    func deleteTemplate(_ template: SessionConfig) {
        data.templates.removeAll { $0.id == template.id }
        persist()
    }

    /// A new session built from a template: fresh id, a name that is not taken,
    /// every setting carried over (blank host and all) for the editor to finish.
    func sessionFromTemplate(_ template: SessionConfig) -> SessionConfig {
        SessionDuplicate.copy(of: template, existingNames: data.sessions.map(\.name))
    }

    // MARK: - MultiExec

    /// Every SSH pane in every window that MultiExec could write to.
    /// Local shell tabs are deliberately absent: broadcast has never included
    /// them. Remote desktops are absent for a better reason — `panes` is the
    /// terminals, so there is nothing there to type into.
    var broadcastCandidates: [TerminalTab] {
        allTabs.filter(\.hasTerminalPanes).flatMap(\.panes)
    }

    /// The panes a keystroke actually reaches — connected, and still ticked.
    var broadcastTargets: [TerminalTab] {
        broadcastCandidates.filter { $0.state == .connected && $0.receivesBroadcast }
    }

    /// True when the user has taken something out of the group, so the UI can
    /// say the broadcast is no longer going everywhere.
    var broadcastIsPartial: Bool {
        BroadcastPolicy.isPartial(broadcastCandidates.map(\.broadcastPane))
    }

    /// Send the same input to every pane in the group, across all windows.
    ///
    /// `origin` is the pane being typed into. It always receives its own
    /// keystrokes even when it has been taken out of the group — a terminal
    /// that ignores your typing is not a feature.
    func broadcastWrite(_ bytes: Data, from origin: UUID? = nil) {
        let candidates = broadcastCandidates
        let ids = BroadcastPolicy.targets(typedIn: origin,
                                          panes: candidates.map(\.broadcastPane))
        for pane in candidates where ids.contains(pane.id) {
            pane.connection?.write(bytes)
        }
    }

    // MARK: - Tunnels

    func upsertTunnel(_ config: TunnelConfig) {
        if let i = data.tunnels.firstIndex(where: { $0.id == config.id }) {
            data.tunnels[i] = config
        } else {
            data.tunnels.append(config)
        }
        persist()
    }

    func deleteTunnel(_ config: TunnelConfig) {
        stopTunnel(config)
        data.tunnels.removeAll { $0.id == config.id }
        persist()
    }

    func toggleTunnel(_ config: TunnelConfig) {
        if activeForwards[config.id] != nil {
            stopTunnel(config)
        } else {
            startTunnel(config)
        }
    }

    private func startTunnel(_ config: TunnelConfig) {
        guard let rawSession = data.sessions.first(where: { $0.id == config.sessionId }) else {
            lastError = "Tunnel \"\(config.name)\" points to a session that no longer exists."
            return
        }
        // A standalone tunnel authenticates as its session, so it must use the
        // same resolved (possibly shared) login the session would, through the
        // same bastion chain.
        let session = resolved(rawSession)
        let chain = jumpChain(for: rawSession)
        Task {
            do {
                let session = try await SecretResolver.resolve(session: session)
                let hops = try await SecretResolver.resolve(sessions: chain)
                if config.type == "dynamic" {
                    let fwd = try await DynamicForward.start(config: config, session: session,
                                                             via: hops, hostKeys: hostKeyVerification)
                    activeForwards[config.id] = .dynamic(fwd)
                } else if config.type == "remote" {
                    // -R keeps a single-hop connection (its inbound channels need
                    // the direct parent); the session's own login is still resolved.
                    let fwd = try await RemoteForward.start(config: config, session: session,
                                                            hostKeys: hostKeyVerification)
                    activeForwards[config.id] = .remote(fwd)
                } else {
                    let fwd = try await LocalForward.start(config: config, session: session,
                                                           via: hops, hostKeys: hostKeyVerification)
                    activeForwards[config.id] = .local(fwd)
                }
            } catch {
                lastError = "Could not start tunnel \"\(config.name)\": \(error)"
            }
        }
    }

    private func stopTunnel(_ config: TunnelConfig) {
        activeForwards[config.id]?.stop()
        activeForwards[config.id] = nil
    }

    /// A session with its login filled in from shared credentials, ready to
    /// connect. The stored session is never rewritten — resolution happens only
    /// at connect time, so the vault keeps the reference, not a copy of the
    /// password. Everything downstream just reads username/password/key off a
    /// SessionConfig and needs to know nothing about credentials.
    func resolved(_ session: SessionConfig) -> SessionConfig {
        CredentialResolver.resolve(session, credentials: data.credentials,
                                   groupCredentials: data.groupCredentials)
    }

    /// The bastions to open to reach `config`, outermost first, each with its
    /// own shared credential resolved. Empty for a direct connection. Follows
    /// the whole `proxyJump` chain (ssh -J c,b,a), not just one hop, and is
    /// cycle-safe — see JumpChain.
    func jumpChain(for config: SessionConfig) -> [SessionConfig] {
        JumpChain.resolve(for: config, sessions: data.sessions).map { resolved($0) }
    }

    func sessionName(for id: String) -> String {
        data.sessions.first { $0.id == id }?.name ?? "?"
    }

    /// Is a host behind a bastion actually reachable? Opening the forward IS
    /// the proof: the chain authenticated and the target accepted the channel.
    ///
    /// This costs a real SSH login, which is why nothing calls it on a timer —
    /// hammering a bastion every few seconds is how you end up locked out.
    func probeViaJumpChain(_ session: SessionConfig) async -> Reachability {
        let started = Date()
        do {
            let chain = try await SecretResolver.resolve(sessions: jumpChain(for: session))
            let resolved = try await SecretResolver.resolve(session: resolved(session))
            let route = try await RemoteDesktopRoute.open(
                target: resolved, via: chain.last, viaHops: chain.dropLast().map { $0 },
                hostKeys: hostKeyVerification)
            route.close()
            return .up(latencyMs: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return .down(reason: "via jump host: \(error.localizedDescription)")
        }
    }

    /// Fetch a one-shot resource snapshot (load/CPU/RAM/uptime) for an SSH
    /// session by running a throwaway command over its own connection — the same
    /// jump chain, credentials and host-key checks a real connect uses.
    /// Put the remote machine's clipboard on this Mac's. A desktop session
    /// cannot supply it — macOS's VNC server never sends one — so the same
    /// machine's shell session is asked instead.
    func copyClipboardFromRemoteDesktop() async {
        let desktops = windows.compactMap { $0.selectedTab?.vnc?.config }
        guard let desktop = desktops.first else {
            lastError = "No remote desktop in front."
            return
        }
        guard let shell = RemoteShellMatch.session(forHost: desktop.host, in: data.sessions) else {
            // Name the host that was looked for: the two sessions are usually
            // written differently, and that is the thing to go and fix.
            let hosts = RemoteShellMatch.shellSessions(in: data.sessions)
                .map(\.host).joined(separator: ", ")
            lastError = "No SSH session with host “\(desktop.host)”."
                + (hosts.isEmpty ? "" : " SSH sessions point at: \(hosts).")
            return
        }
        do {
            let resolved = try await SecretResolver.resolve(session: shell)
            let chain = try await SecretResolver.resolve(sessions: jumpChain(for: shell))
            let text = try await SSHConnection.runCommand(
                RemoteShellMatch.readClipboardCommand, config: resolved,
                hostKeys: hostKeyVerification, jumps: chain)
            guard !text.isEmpty else {
                infoMessage = "The remote clipboard is empty."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            infoMessage = "Copied \(text.count) characters from \(shell.name)."
        } catch {
            lastError = "Could not read the remote clipboard: \(error.localizedDescription)"
        }
    }

    /// Close the pane a dead terminal sits in, wherever it lives. The pane
    /// knows nothing about windows, and closing the last pane of a tab closes
    /// the tab — which is what "close this" means when only one is left.
    func closePaneHoldingDeadTerminal(_ pane: TerminalTab) {
        for window in windows {
            if let tab = window.tabs.first(where: { $0.localTerminal === pane }) {
                window.closeTab(tab)
                return
            }
            if let tab = window.tabs.first(where: { $0.panes.contains { $0 === pane } }) {
                window.closePane(pane, in: tab)
                return
            }
        }
    }

    func remoteStats(for session: SessionConfig) async throws -> RemoteStats {
        let resolved = try await SecretResolver.resolve(session: session)
        let chain = jumpChain(for: session)
        let resolvedChain = try await SecretResolver.resolve(sessions: chain)
        let output = try await SSHConnection.runCommand(
            RemoteStatsProbe.command, config: resolved,
            hostKeys: hostKeyVerification, jumps: resolvedChain)
        return RemoteStatsProbe.parse(output)
    }
}

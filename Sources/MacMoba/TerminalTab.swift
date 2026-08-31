// One terminal tab = one SwiftTerm view + one SSHConnection.
// The tab object is the SwiftTerm delegate: keystrokes -> ssh, ssh -> feed.

import AppKit
import Foundation
import MacMobaCore
import SwiftTerm
import SwiftUI

final class TerminalTab: NSObject, ObservableObject, Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case closed(String)
    }

    let id = UUID()
    let config: SessionConfig
    let termView: TerminalView

    @Published var state: State = .connecting
    /// This pane rang the bell or resumed after silence while nobody was
    /// looking (cmux-style attention). Cleared when the pane gains focus.
    @Published private(set) var needsAttention = false
    /// Whether MultiExec writes to this pane. On by default, so switching
    /// broadcast on behaves as it always has until something is unticked.
    @Published var receivesBroadcast = true
    @Published var title: String

    /// Set by SessionTab: fired when this pane's terminal view gains focus.
    var onFocused: (() -> Void)?

    /// Whatever is carrying this pane — SSH or Telnet. The pane only ever
    /// writes, resizes and closes, so it does not need to know which.
    private(set) var connection: (any TerminalTransport)?
    /// Port forward backing a tunnelled Telnet session, closed with it.
    private var route: RemoteDesktopRoute?
    /// The X11 remote forward, when this session forwards X11; torn down on exit.
    private var x11Forward: RemoteForward?
    private weak var app: AppState?
    private var userClosed = false
    /// Drives an expect/send login sequence, fed from `receive` until complete.
    /// Lives on the connection's receive thread; nil when there is no sequence.
    private let expectBox = ExpectBox()
    /// Watches the stream for bell / resumed-after-silence (cmux-style).
    private let attentionBox = AttentionBox()
    /// Detects and drives a ZMODEM download (a remote `sz`), saving to Downloads.
    private lazy var zmodemBox: ZModemBox = {
        let box = ZModemBox()
        box.onComplete = { [weak self] files in
            DispatchQueue.main.async { self?.saveZModemFiles(files) }
        }
        box.onSendComplete = { [weak self] name in
            DispatchQueue.main.async { self?.postStatus("ZMODEM: sent \(name).") }
        }
        return box
    }()

    /// Push a local file to the remote over ZMODEM (launches `rz` there). Only
    /// meaningful for a live terminal session.
    @MainActor
    func sendFileViaZModem(_ url: URL) {
        guard state == .connected else { postStatus("Not connected.", isError: true); return }
        guard let data = try? Data(contentsOf: url) else {
            postStatus("Could not read \(url.lastPathComponent).", isError: true)
            return
        }
        postStatus("ZMODEM: sending \(url.lastPathComponent) …")
        zmodemBox.beginSend(name: url.lastPathComponent, data: [UInt8](data),
                            write: { [weak self] out in self?.connection?.write(Data(out)) })
    }
    /// Lock-protected: written on the main thread, read on the SSH event loop.
    private let loggerBox = LoggerBox()

    /// Where this pane's output is being written, if logging is on.
    var logURL: URL? { loggerBox.current?.url }

    @MainActor
    init(config: SessionConfig, app: AppState) {
        self.config = config
        self.app = app
        self.title = config.name
        self.termView = ClipboardTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        // SwiftTerm keeps 500 lines unless told otherwise — a few seconds of a
        // build log.
        termView.getTerminal().changeScrollback(TerminalDefaults.scrollback())
        TerminalRendering.apply(to: termView)
        super.init()
        termView.terminalDelegate = self
        applyFont(size: app.terminalFontSize)
        app.theme.apply(to: termView)
    }

    /// Redial after the Mac wakes, but only when it makes sense: the pane must
    /// have dropped (a session that survived sleep keeps its shell and scrollback
    /// — do not throw that away), and the user must not have closed it. The
    /// caller waits a moment after wake so a dead socket has surfaced as closed.
    @MainActor
    func reconnectAfterWake() {
        guard WakeReconnectPolicy.shouldReconnect(wasConnectedAtSleep: true,
                                                  closedByUserSinceSleep: userClosed) else { return }
        if case .closed = state { connect() }
    }

    /// Type the session's startup commands into the shell, once it is up. Runs
    /// on every connect — including a reconnect after sleep or a dropped link —
    /// so the session comes back to the same place (its directory, its `tail`,
    /// its tmux) rather than a bare prompt. Sent straight to this connection,
    /// never broadcast. A short delay lets the login banner and prompt land
    /// first, so the commands are not swallowed or interleaved.
    @MainActor
    private func runOnConnectCommands() {
        // Replacement tokens (%host%, %username%…) resolve here, so a template's
        // script is filled in with this session's own values.
        let expanded = TokenExpander.expand(config.onConnectCommands, in: config)
        let keys = OnConnectScript.keystrokes(expanded)
        guard !keys.isEmpty else { return }
        let connectionAtSend = connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Only if still the same live connection — a fast reconnect must not
            // fire the previous attempt's script into the new shell.
            guard let self, self.connection === connectionAtSend,
                  self.state == .connected else { return }
            self.connection?.write(Data(keys.utf8))
        }
    }

    /// Bring up X11 over a remote forward and point the remote DISPLAY at it.
    /// Native ssh X11 is not possible on this SSH stack (NIOSSH has no x11
    /// channel), so this asks the server to listen on 127.0.0.1:(6000+N) and
    /// tunnels that back to XQuartz, then exports DISPLAY on the shell. Needs
    /// XQuartz running with TCP listening enabled.
    @MainActor
    private func startX11Forwarding() {
        guard X11Local.isXServerRunning else {
            postStatus("X11 forwarding: no local X server (start XQuartz).", isError: true)
            return
        }
        let display = X11Forwarding.defaultRemoteDisplay
        let cookie = X11Local.cookie()
        let connectionAtSend = connection
        Task {
            do {
                let route = try await resolvedRoute()
                let cfg = X11Forwarding.remoteForwardConfig(sessionId: config.id, display: display)
                let forward = try await RemoteForward.start(
                    config: cfg, session: route.config, hostKeys: app?.hostKeyVerification)
                await MainActor.run {
                    // A reconnect may have replaced the connection while we set
                    // up; only drive the shell that asked for this.
                    guard self.connection === connectionAtSend, self.state == .connected else {
                        forward.stop()
                        return
                    }
                    self.x11Forward = forward
                    let setup = X11Forwarding.remoteSetup(display: display, cookieHex: cookie)
                    self.connection?.write(Data((setup + "\n").utf8))
                }
            } catch {
                await MainActor.run { self.postStatus("X11 forwarding failed: \(error)", isError: true) }
            }
        }
    }

    /// What the status bar names as the far end. Mosh shows user@host too: it
    /// is an SSH login, and leaving the user out makes a failed login harder
    /// to diagnose.
    var statusTarget: String {
        if config.sessionKind == .serial {
            return "\(config.host) @ \(config.serialSettings.baud) \(config.serialSettings.formatString)"
        } else if config.sessionKind.authenticatesOverSSH {
            return "\(config.username)@\(config.host):\(config.port)"
        } else {
            return "\(config.host):\(config.port)"
        }
    }

    @MainActor
    func connect() {
        userClosed = false
        state = .connecting
        // A fresh attempt starts with a clean message area; connection progress
        // itself is the status bar's persistent left side, driven by `state`.
        clearStatus()
        let term = termView.getTerminal()
        Task {
            do {
                let conn: any TerminalTransport
                switch config.sessionKind {
                case .telnet: conn = try await connectTelnet(cols: term.cols, rows: term.rows)
                case .rlogin: conn = try await connectRlogin(cols: term.cols, rows: term.rows)
                case .mosh:   conn = try await connectMosh(cols: term.cols, rows: term.rows)
                case .serial: conn = try connectSerial()
                default:      conn = try await connectSSH(cols: term.cols, rows: term.rows)
                }
                self.connection = conn
                self.state = .connected
                // The view may have been laid out while we were connecting.
                conn.resize(cols: term.cols, rows: term.rows)
                self.runOnConnectCommands()
                // Expect/send runs off the receive thread as output arrives;
                // arm it here so the first prompt is already being watched for.
                self.expectBox.start(self.config.expectSequence)
                if self.config.x11Forwarding == true,
                   self.config.sessionKind.authenticatesOverSSH {
                    self.startX11Forwarding()
                }
            } catch {
                // The failure reason travels in the state itself; the status
                // bar turns red and offers the full text in a popover.
                self.state = .closed("\(error)")
            }
        }
    }

    /// The target and its jump chain with both shared credentials and any
    /// password-manager references (op://, cmd:) resolved — ready for the SSH
    /// layer, which only ever sees literal secrets.
    private func resolvedRoute() async throws -> (config: SessionConfig, jumps: [SessionConfig]) {
        let resolvedConfig = try await SecretResolver.resolve(session: config)
        var chain: [SessionConfig] = []
        if let app { chain = await app.jumpChain(for: config) }
        let resolvedChain = try await SecretResolver.resolve(sessions: chain)
        return (resolvedConfig, resolvedChain)
    }

    private func connectSSH(cols: Int, rows: Int) async throws -> any TerminalTransport {
        let route = try await resolvedRoute()
        return try await SSHConnection.connect(
            config: route.config,
            cols: cols,
            rows: rows,
            hostKeys: app?.hostKeyVerification,
            jumps: route.jumps,
            onData: { [weak self] data in self?.receive(data) },
            onExit: { [weak self] reason in
                DispatchQueue.main.async { self?.handleExit(reason) }
            }
        )
    }

    /// Telnet has no authentication and no encryption of its own, so the only
    /// privacy available is an SSH session underneath it — the same port
    /// forward VNC and RDP use.
    private func connectTelnet(cols: Int, rows: Int) async throws -> any TerminalTransport {
        // open() handles the no-jump case itself, reporting the direct address.
        // Only the SSH gateways need secrets resolved — Telnet has no login.
        let chain = try await resolvedRoute().jumps
        let opened = try await RemoteDesktopRoute.open(
            target: config,
            via: chain.last,
            viaHops: chain.dropLast().map { $0 },
            hostKeys: app?.hostKeyVerification)
        self.route = opened
        var target = config
        target.host = opened.host
        target.port = opened.port
        return try await TelnetConnection.connect(
            config: target,
            cols: cols,
            rows: rows,
            onData: { [weak self] data in self?.receive(data) },
            onExit: { [weak self] reason in
                DispatchQueue.main.async { self?.handleExit(reason) }
            }
        )
    }

    /// Rlogin, tunnelled through the SSH jump chain exactly like Telnet — it is
    /// cleartext, so making the hop private matters. `RemoteDesktopRoute` gives a
    /// local address to dial when there is a gateway.
    private func connectRlogin(cols: Int, rows: Int) async throws -> any TerminalTransport {
        let chain = try await resolvedRoute().jumps
        let opened = try await RemoteDesktopRoute.open(
            target: config,
            via: chain.last,
            viaHops: chain.dropLast().map { $0 },
            hostKeys: app?.hostKeyVerification)
        self.route = opened
        var target = config
        target.host = opened.host
        target.port = opened.port
        return try await RloginConnection.connect(
            config: target,
            localUser: NSUserName(),
            cols: cols,
            rows: rows,
            onData: { [weak self] data in self?.receive(data) },
            onExit: { [weak self] reason in
                DispatchQueue.main.async { self?.handleExit(reason) }
            })
    }

    /// A serial line: open the device in `host` at the session's baud/format.
    /// No network, no login — the terminal just talks to whatever is on the wire.
    private func connectSerial() throws -> any TerminalTransport {
        try SerialConnection.connect(
            device: config.host,
            settings: config.serialSettings,
            onData: { [weak self] data in self?.receive(data) },
            onExit: { [weak self] reason in
                DispatchQueue.main.async { self?.handleExit(reason) }
            })
    }

    /// Mosh in two steps: SSH once to start `mosh-server` and read back the UDP
    /// port and session key, then hand those to the bundled mosh-client, which
    /// speaks SSP over UDP from then on. The SSH connection is not kept — that
    /// is the point of Mosh, the session outlives the TCP one that started it.
    private func connectMosh(cols: Int, rows: Int) async throws -> any TerminalTransport {
        await MainActor.run { postStatus("Starting mosh-server over SSH ...") }
        let route = try await resolvedRoute()
        let output = try await SSHConnection.runCommand(
            MoshBootstrap.serverCommand(),
            config: route.config,
            hostKeys: app?.hostKeyVerification,
            jumps: route.jumps)
        let session = try MoshBootstrap.parse(output)
        await MainActor.run {
            postStatus("Connected to UDP port \(session.port); roaming enabled.")
        }
        return try MoshTransport(
            session: session,
            host: MoshBootstrap.datagramHost(for: config),
            cols: cols,
            rows: rows,
            onData: { [weak self] data in self?.receive(data) },
            onExit: { [weak self] reason in
                DispatchQueue.main.async { self?.handleExit(reason) }
            })
    }

    private func receive(_ data: Data) {
        loggerBox.current?.append(data)
        if let trigger = attentionBox.observe([UInt8](data)) {
            DispatchQueue.main.async { [weak self] in self?.applyAttention(trigger) }
        }
        // A remote `sz` turns the stream into a ZMODEM download; once that is
        // detected the bytes are the protocol's, not terminal output.
        if zmodemBox.handle([UInt8](data), write: { [weak self] out in self?.connection?.write(Data(out)) }) {
            return
        }
        // Feed the expect/send sequence, if one is running, and type its
        // responses back into the same connection.
        if expectBox.isActive {
            let text = String(decoding: data, as: UTF8.self)
            for send in expectBox.feed(text) {
                connection?.write(Data(send.utf8))
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.termView.feed(byteArray: ArraySlice([UInt8](data)))
        }
    }

    /// Write the files a ZMODEM download delivered into ~/Downloads.
    @MainActor
    private func saveZModemFiles(_ files: [ZModemReceiver.ReceivedFile]) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        var saved: [String] = []
        for file in files {
            guard let dir else { continue }
            let safe = file.name.replacingOccurrences(of: "/", with: "_")
            let url = dir.appendingPathComponent(safe)
            do { try file.data.write(to: url); saved.append(safe) } catch {}
        }
        if saved.isEmpty {
            postStatus("ZMODEM: transfer finished but nothing could be saved.", isError: true)
        } else {
            postStatus("ZMODEM: saved \(saved.joined(separator: ", ")) to Downloads.")
        }
    }

    @MainActor
    private func handleExit(_ reason: String) {
        guard state == .connected || state == .connecting else { return }
        // The reason travels in the state; the status bar shows it persistently.
        state = .closed(reason)
        x11Forward?.stop()
        x11Forward = nil
    }

    func disconnect() {
        userClosed = true
        stopLogging()
        connection?.close()
        connection = nil
        route?.close()
        route = nil
        x11Forward?.stop()
        x11Forward = nil
    }

    /// Toggle output logging for this pane. Returns the log file when starting.
    @MainActor
    @discardableResult
    func toggleLogging() -> URL? {
        if loggerBox.current != nil {
            stopLogging()
            postStatus("Session logging stopped.")
            return nil
        }
        guard let logger = SessionLogger(sessionName: config.name) else {
            postStatus("Could not create log file.", isError: true)
            return nil
        }
        // Include what is already on screen, so the log starts with the
        // history you can see rather than only what happens next.
        logger.appendScrollback(dumpScrollback())
        loggerBox.set(logger)
        postStatus("Logging to \(logger.url.path)")
        return logger.url
    }

    /// Plain text of the whole buffer (scrollback + visible screen).
    @MainActor
    func dumpScrollback() -> String {
        let terminal = termView.getTerminal()
        let (_, rows) = terminal.getDims()
        let top = terminal.getTopVisibleRow()
        var lines: [String] = []
        for row in min(0, top)..<(top + rows) {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        // Drop the blank tail of the screen.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private func stopLogging() {
        loggerBox.current?.close()
        loggerBox.set(nil)
    }

    // MARK: - Image paste to remote

    /// A pasted screenshot becomes a file on the remote and its path appears in
    /// the prompt — nothing is "run": the user keeps composing (for an agent,
    /// usually) and presses Return themselves.
    @MainActor
    func pasteImageToRemote(_ png: Data) {
        guard state == .connected else {
            postStatus("Not connected — image not uploaded.", isError: true)
            return
        }
        postStatus("Uploading pasted image…")
        let stamp = Int(Date().timeIntervalSince1970)
        Task {
            do {
                let route = try await resolvedRoute()
                let path = try await RemotePasteUpload.upload(
                    data: png, fileName: "paste-\(stamp).png",
                    config: route.config, jumps: route.jumps,
                    hostKeys: app?.hostKeyVerification)
                await MainActor.run {
                    self.connection?.write(Data(path.utf8))
                    self.postStatus("Image uploaded: \(path)")
                }
            } catch {
                await MainActor.run {
                    self.postStatus("Image paste failed: \(error)", isError: true)
                }
            }
        }
    }

    // MARK: - Attention (cmux-style)

    /// A trigger only matters when nobody is looking at this pane: while it is
    /// focused in the key window of an active app, the user IS the attention.
    @MainActor
    private func applyAttention(_ trigger: AttentionDetector.Trigger) {
        let activelyWatched = NSApp.isActive
            && termView.window?.isKeyWindow == true
            && termView.window?.firstResponder === termView
        guard !activelyWatched else { return }
        needsAttention = true
        // Away from the app entirely → a system notification carries the pane
        // back into view; inside the app the tab badge is enough.
        if !NSApp.isActive {
            let reason: String
            switch trigger {
            case .bell: reason = "rang the bell"
            case .resumedAfterSilence(let s): reason = "resumed output after \(Int(s))s of silence"
            }
            AttentionNotifier.post(title: title, body: "\(statusTarget) \(reason)", paneID: id)
        }
    }

    @MainActor
    func clearAttention() {
        if needsAttention { needsAttention = false }
    }

    // MARK: - Status messages (P0-2)
    //
    // App-generated messages go to the pane's status bar, never into the
    // terminal buffer: the scrollback carries only what the remote actually
    // sent, so ⌘F finds real output and reconnects leave no debris behind.

    /// One transient message for the pane's status bar.
    struct PaneStatus: Equatable {
        enum Level { case info, error }
        let text: String
        let level: Level
    }

    /// The message currently showing, if any. Transient — the persistent left
    /// side of the bar derives from `state` directly.
    @Published private(set) var status: PaneStatus?
    private var statusQueue: [PaneStatus] = []
    private var statusDismiss: DispatchWorkItem?
    private var statusHovered = false

    /// Show `text` briefly in the status bar. Messages queue rather than
    /// overwrite, so two quick events both get read.
    @MainActor
    func postStatus(_ text: String, isError: Bool = false) {
        statusQueue.append(PaneStatus(text: text, level: isError ? .error : .info))
        pumpStatus()
    }

    /// The bar hovers-to-hold: pausing dismissal keeps a message readable.
    @MainActor
    func setStatusHovered(_ hovering: Bool) {
        statusHovered = hovering
        if hovering {
            statusDismiss?.cancel()
        } else if status != nil {
            scheduleStatusDismiss(after: 2)
        }
    }

    @MainActor
    private func pumpStatus() {
        guard status == nil, !statusQueue.isEmpty else { return }
        status = statusQueue.removeFirst()
        if !statusHovered { scheduleStatusDismiss(after: 4) }
    }

    @MainActor
    private func scheduleStatusDismiss(after seconds: TimeInterval) {
        statusDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.status = nil
            self?.pumpStatus()
        }
        statusDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @MainActor
    private func clearStatus() {
        statusDismiss?.cancel()
        statusQueue.removeAll()
        status = nil
    }
}

// MARK: - SwiftTerm delegate

extension TerminalTab: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        Task { @MainActor in
            if case .closed = state {
                // Nothing can be typed into a dead session, so the only keys
                // that mean anything are the two ways out of it.
                switch DeadTerminalKey.action(for: Array(bytes)) {
                case .reconnect: connect(); return
                case .close: app?.closePaneHoldingDeadTerminal(self); return
                case .ignore: return
                }
            }
            if let app, app.broadcastInput {
                app.broadcastWrite(bytes, from: self.id)
            } else {
                connection?.write(bytes)
            }
        }
    }

    /// This pane as the broadcast rules see it.
    var broadcastPane: BroadcastPane {
        BroadcastPane(id: id, isConnected: state == .connected,
                      receivesBroadcast: receivesBroadcast)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        connection?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor in
            self.title = title.isEmpty ? config.name : title
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// Terminal bell → macOS notification, so a long-running command can tell
    /// you it finished while MacMoba is in the background. Suppressed while the
    /// app is frontmost (you can already see it) and rate-limited, because some
    /// shells ring the bell on every tab-completion.
    func bell(source: TerminalView) {
        Task { @MainActor in
            guard !NSApp.isActive else { return }
            let now = Date()
            guard now.timeIntervalSince(Self.lastBell) > 5 else { return }
            Self.lastBell = now
            let note = NSUserNotification()
            note.title = "MacMoba — \(config.name)"
            note.informativeText = "The session rang the terminal bell."
            NSUserNotificationCenter.default.deliver(note)
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    @MainActor private static var lastBell = Date.distantPast
}

// MARK: - SwiftUI wrapper

/// Hosts the terminal view and reports focus: SwiftTerm's responder overrides
/// aren't `open`, so focus is detected by observing the window's firstResponder.
final class PaneContainerView: NSView {
    let termView: TerminalView
    var onFocusGained: (() -> Void)?
    private var observation: NSKeyValueObservation?

    init(termView: TerminalView) {
        self.termView = termView
        super.init(frame: .zero)
        adoptTerminal()
    }

    /// Make sure this container is the one holding the terminal.
    ///
    /// A pane's TerminalView is a single AppKit view, and rebuilding the split
    /// tree (merging tabs, tiling, closing a pane) creates a fresh container
    /// for the same pane. Whichever container is built last takes the terminal
    /// with it — so if SwiftUI then keeps an EARLIER container on screen, that
    /// pane draws nothing at all: correct border, correct badge, empty middle.
    /// Re-adding is cheap and idempotent, so it runs on every update.
    func adoptTerminal() {
        guard termView.superview !== self else { return }
        termView.removeFromSuperview()
        termView.frame = bounds
        addSubview(termView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Deterministic child sizing: autoresizing masks mis-track when the
    // terminal view is re-parented on split-tree changes (e.g. closing a
    // pane), so pin the terminal to our size on every frame change.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        termView.frame = CGRect(origin: .zero, size: newSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Going on screen is exactly when a container must own its terminal.
        if window != nil { adoptTerminal() }
        guard let window else {
            observation = nil
            return
        }
        observation = window.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self,
                      let responder = self.window?.firstResponder as? NSView,
                      responder.isDescendant(of: self) else { return }
                self.onFocusGained?()
            }
        }
    }

    override func layout() {
        super.layout()
        termView.frame = bounds
    }
}

extension TerminalTab {
    /// Push the terminal's current cols/rows to the remote PTY. Used after
    /// split-tree changes, where the view may have been re-parented and the
    /// implicit resize chain can be missed.
    @MainActor
    func syncRemoteSize() {
        let terminal = termView.getTerminal()
        connection?.resize(cols: terminal.cols, rows: terminal.rows)
    }

    @MainActor
    func applyFont(size: Double) {
        termView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

struct TerminalHostView: NSViewRepresentable {
    let tab: TerminalTab

    func makeNSView(context: Context) -> PaneContainerView {
        let container = PaneContainerView(termView: tab.termView)
        container.onFocusGained = { [weak tab] in tab?.onFocused?() }
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(container.termView)
        }
        return container
    }

    func updateNSView(_ nsView: PaneContainerView, context: Context) {
        // Self-healing: see PaneContainerView.adoptTerminal.
        nsView.adoptTerminal()
    }
}

/// Wraps the attention detector for the receive thread: bytes go in there,
/// triggers come back; the lock guards the detector's parser state.
final class AttentionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = AttentionDetector()

    func observe(_ bytes: [UInt8]) -> AttentionDetector.Trigger? {
        lock.lock(); defer { lock.unlock() }
        return detector.observe(bytes, at: Date().timeIntervalSinceReferenceDate)
    }
}

/// Thread-safe home for a running `ExpectMachine`. `receive` runs on the
/// connection's read thread; this guards the machine so arming it (main thread)
/// and feeding it (read thread) don't race, and answers `isActive` cheaply so
/// the common no-sequence case adds nothing to the hot path.
final class ExpectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var machine: ExpectMachine?

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return machine != nil
    }

    func start(_ steps: [ExpectStep]?) {
        guard let steps, !steps.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        machine = ExpectMachine(steps: steps)
    }

    /// Feed output; returns what to send. Drops the machine once complete so
    /// later output takes the cheap `isActive == false` path.
    func feed(_ text: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let m = machine else { return [] }
        let sends = m.feed(text)
        if m.isComplete { machine = nil }
        return sends
    }
}

/// Watches the terminal stream for a ZMODEM transfer (a remote `sz`) and, once
/// one starts, drives the receiver to completion. Lives on the receive thread;
/// the lock guards the transition into and out of receive mode.
final class ZModemBox: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: ZModemReceiver?
    private var sender: ZModemSender?
    private var tail: [UInt8] = []
    /// Set while a receiver on the remote is announcing itself — someone ran
    /// `rz` by hand. Typing `rz` at it would feed the word into the transfer.
    private var remoteReceiverWaiting = false
    var onComplete: (([ZModemReceiver.ReceivedFile]) -> Void)?
    var onSendComplete: ((String) -> Void)?

    /// Begin sending a file: launch the remote receiver with `rz`, then start the
    /// ZMODEM sender. Inbound bytes are routed to it until it signs off.
    func beginSend(name: String, data: [UInt8], write: ([UInt8]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard sender == nil, receiver == nil else { return }
        let s = ZModemSender(name: name, data: data)
        sender = s
        // Normally the remote has no receiver yet and one is started here, the
        // way MobaXterm does it. But if the user ran `rz` themselves — the
        // obvious thing to try — it is already waiting, and typing the command
        // at it would arrive as transfer data and wedge both ends.
        if !remoteReceiverWaiting { write(Array("rz\r".utf8)) }
        remoteReceiverWaiting = false
        let initial = s.start()
        if !initial.isEmpty { write(initial) }
    }

    /// Handle inbound bytes. Returns true when they belong to a ZMODEM transfer
    /// and should not be shown as terminal output; `write` sends protocol
    /// responses back to the remote.
    func handle(_ bytes: [UInt8], write: ([UInt8]) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let s = sender {
            let response = s.feed(bytes)
            if !response.isEmpty { write(response) }
            if s.isComplete {
                let name = s.name
                sender = nil; tail = []
                onSendComplete?(name)
            }
            return true
        }
        if let r = receiver {
            let response = r.feed(bytes)
            if !response.isEmpty { write(response) }
            if r.isComplete {
                let files = r.files
                receiver = nil; tail = []
                onComplete?(files)
            }
            return true
        }
        // Not yet transferring: look for the announce sequence, joining a little
        // of the previous chunk in case it straddles a read boundary.
        let combined = tail + bytes
        if let idx = ZModem.receiveTriggerIndex(in: combined) {
            let r = ZModemReceiver()
            receiver = r
            let response = r.feed(Array(combined[idx...]))
            if !response.isEmpty { write(response) }
            tail = []
            return true
        }
        // An idle stream carrying ZRINIT means someone started `rz` by hand.
        // Remembered, not consumed: it is still terminal output until a
        // transfer actually begins.
        if ZModem.receiverIsWaiting(in: combined) { remoteReceiverWaiting = true }
        tail = Array(combined.suffix(8))
        return false
    }
}

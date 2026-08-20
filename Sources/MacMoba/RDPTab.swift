// One RDP tab = one FreeRDP connection + its framebuffer view.
//
// Same shape as VNCTab, and for the same reason: SessionTab and the tab chips
// should not care which protocol a tab speaks. The FreeRDP side runs on its own
// thread inside CMacMobaRDP, so every callback here hops to the main actor.

import AppKit
import CMacMobaRDP
import Foundation
import MacMobaCore
import SwiftUI

@MainActor
final class RDPTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let config: SessionConfig

    @Published var state: TerminalTab.State = .connecting
    @Published var title: String
    @Published var statusLine = ""

    let container = RDPContainerView()

    private var handle: OpaquePointer?
    private var rdp: UnsafeMutableRawPointer?
    private var route: RemoteDesktopRoute?
    private weak var app: AppState?
    /// The session with its password-manager reference resolved, set at connect.
    private var resolvedConfig: SessionConfig?
    private var userClosed = false

    /// Where FreeRDP's own log goes. Kept next to the session logs so it is
    /// easy to find and attach to a bug report.
    static let logURL: URL = SessionLogger.directory
        .appendingPathComponent("MacMoba-RDP.log")

    private static var loggingConfigured = false

    init(config: SessionConfig, app: AppState) {
        self.config = config
        self.app = app
        self.title = config.name
        super.init()
        container.onInput = { [weak self] event in self?.send(event) }
        container.onResize = { [weak self] size in self?.requestResize(to: size) }
        // Which part of the desktop this tab shows depends on which display it
        // is on, so both "the window moved" and "the displays changed" have to
        // re-slice it. Without the first, dragging a spanning session to the
        // other screen leaves it showing the screen it came from.
        container.onScreenChanged = { [weak self] in self?.screenConfigurationChanged() }
        // Selector-based on purpose: that kind of observer is dropped
        // automatically when the tab goes away, so there is no token to
        // remember and no way to leave one behind on a reconnect.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Self.configureLoggingOnce()
    }

    @objc private func screensChanged() { screenConfigurationChanged() }

    /// FreeRDP's diagnosis of a failed connection is in its own log, which
    /// otherwise only exists on stderr — invisible unless the app was launched
    /// from a terminal.
    private static func configureLoggingOnce() {
        guard !loggingConfigured else { return }
        loggingConfigured = true
        try? FileManager.default.createDirectory(
            at: SessionLogger.directory, withIntermediateDirectories: true)
        logURL.path.withCString { macmoba_rdp_set_log_file($0) }
    }

    func connect() {
        userClosed = false
        state = .connecting
        let chain = app?.jumpChain(for: config) ?? []
        let via = chain.last
        statusLine = via == nil
            ? "Connecting to \(config.host):\(config.port) …"
            : "Connecting to \(config.host):\(config.port) via \(via!.name) …"

        Task {
            do {
                // Resolve op:// / cmd: references — the gateway chain and the
                // Windows password.
                let resolvedChain = try await SecretResolver.resolve(sessions: chain)
                self.resolvedConfig = try await SecretResolver.resolve(session: config)
                let route = try await RemoteDesktopRoute.open(
                    target: config, via: resolvedChain.last,
                    viaHops: resolvedChain.dropLast().map { $0 },
                    hostKeys: app?.hostKeyVerification)
                self.route = route
                self.start(host: route.host, port: route.port)
            } catch {
                self.fail("Could not open the tunnel: \(error)")
            }
        }
    }

    private func start(host: String, port: Int) {
        // Retained, not unretained: the connection thread can outlive this tab
        // being closed (see macmoba_rdp_free), and a callback arriving in that
        // window must not land on a deallocated object. `onRelease` gives the
        // reference back once the C side is finished with us.
        let context = Unmanaged.passRetained(self).toOpaque()
        guard let rdp = macmoba_rdp_create(context, onFrame, onState,
                                           onCertificate, onRelease) else {
            fail("Could not create the RDP client.")
            return
        }
        self.rdp = UnsafeMutableRawPointer(rdp)

        // Ask for the desktop in real pixels, not points. A server that opened
        // the display-control channel gets corrected on the first resize anyway,
        // but one that did not keeps whatever it was given at connect time — so
        // without the scale here a Retina display is stuck upscaling a
        // half-resolution desktop for the life of the session.
        // A fixed size wins outright: the point of choosing it is that the
        // desktop does not move when the window does.
        // Normally NOT spanning here, even when the session is set to use all
        // displays. "Use all displays" only takes effect in full screen — that
        // is the only time the session owns the other screens — and spanning at
        // connect time gave a WINDOWED session a desktop the size of every
        // screen put together, which is unusable and looks exactly like the
        // wrong resolution being negotiated. The layout is normally sent over
        // the display-control channel when full screen starts; `connectSpanning`
        // is the fallback for a server that will only take one at connect time.
        monitors = connectSpanning ? Self.currentMonitors() : []
        // A reconnect after a spanning session would otherwise keep showing the
        // slice the old desktop had.
        container.sourceRect = nil
        let desktop: (width: Int, height: Int)
        if !monitors.isEmpty {
            // The one case that must exceed a single screen.
            desktop = RDPMonitorLayout.boundingSize(of: monitors)
        } else if let fixed = config.fixedDesktopSize {
            desktop = RDPDesktopSize.capped(fixed, toScreenPixels: hostScreenPixels)
        } else {
            desktop = RDPDesktopSize.pixels(forPoints: container.bounds.size,
                                            scale: container.backingScale,
                                            enforceMinimum: true,
                                            screenPixels: hostScreenPixels)
        }
        let width = desktop.width
        let height = desktop.height
        container.requestedSize = CGSize(width: width, height: height)

        // A username typed as DOMAIN\\user is split here, so people can enter it
        // the way Windows shows it rather than hunting for the Domain field.
        var user = config.username
        var domain = config.domain ?? ""
        if let slash = user.firstIndex(of: "\\") {
            if domain.isEmpty { domain = String(user[user.startIndex..<slash]) }
            user = String(user[user.index(after: slash)...])
        }
        let security = RDPSecurity(rawValue: config.rdpSecurity ?? "") ?? .negotiate
        let securityCode: Int32
        switch security {
        case .negotiate: securityCode = 0
        case .nla: securityCode = 1
        case .tls: securityCode = 2
        case .rdp: securityCode = 3
        }
        macmoba_rdp_set_clipboard_callback(rdp, onClipboard, onClipboardImage)
        macmoba_rdp_set_file_callbacks(rdp, onFileList, onFileChunk)
        fileTransfers.requestRange = { [weak self] requestId, index, offset, length in
            guard let self, let client = self.rdp else { return false }
            return macmoba_rdp_request_file_range(OpaquePointer(client), requestId,
                                                  index, offset, length)
        }

        // Shared folders become redirected drives. The C strings must outlive
        // the call, so they are held for its duration rather than built inline.
        let drives = config.driveRedirections
        var monitorDefs = monitors.map {
            MacMobaRDPMonitor(x: $0.x, y: $0.y, width: $0.width, height: $0.height,
                              isPrimary: $0.isPrimary, scalePercent: $0.scalePercent)
        }
        let ok = drives.withCStringArray { pointers in
            monitorDefs.withUnsafeMutableBufferPointer { buffer in
                macmoba_rdp_connect(rdp, host, Int32(port),
                                    user, (resolvedConfig ?? config).password ?? "",
                                    domain, Int32(width), Int32(height), securityCode,
                                    // Display control is asked for whenever the
                                    // desktop may follow the window — it is also
                                    // the only way to span without reconnecting.
                                    // Never alongside a baked-in layout: one
                                    // display-control resize carries a single
                                    // rectangle and would flatten it.
                                    RDPResizePolicy.allowsDynamicResize(
                                        spansDisplays: !monitors.isEmpty,
                                        fitsWindow: config.displayMode == .fitWindow),
                                    config.rdpAlternateShell,
                                    pointers, Int32(drives.count),
                                    buffer.baseAddress, Int32(buffer.count))
            }
        }
        if !ok {
            fail("Could not start the RDP connection.")
        } else {
            startWatchingPasteboard()
        }
    }

    /// The Mac pasteboard has no change notification, so it is polled — the
    /// same approach AppKit apps have always used. Only the change counter is
    /// read unless something actually changed.
    private func startWatchingPasteboard() {
        // Offer whatever is already on the pasteboard. Watching only for
        // *changes* would mean text copied before connecting is invisible to
        // the session until you copy something else.
        pasteboardCount = NSPasteboard.general.changeCount - 1
        pasteboardTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushPasteboardIfChanged() }
        }
        pasteboardTimer = timer
    }

    private func pushPasteboardIfChanged() {
        guard let rdp, state == .connected else { return }
        let board = NSPasteboard.general
        guard board.changeCount != pasteboardCount else { return }
        // Our own writes are already accounted for: every place that writes to
        // the pasteboard updates pasteboardCount straight after, so the guard
        // above swallows them. A separate one-shot "suppress" flag was worse
        // than redundant — when a write happened while the flag was still set,
        // the flag was consumed by the user's *next* copy instead, silently
        // dropping it.
        pasteboardCount = board.changeCount
        let client = OpaquePointer(rdp)
        // Files first: a Finder copy also puts the file's name on as text, and
        // sending the name instead of the file is never what was meant.
        if let paths = RDPFileClipboard.localFilePaths(from: board) {
            paths.withCString { macmoba_rdp_offer_files(client, $0) }
            return
        }
        macmoba_rdp_offer_files(client, nil)
        let text = board.string(forType: .string)
        // Only look for a picture when there is no text: a copied selection
        // often carries both, and the text is what was meant.
        let dib = text == nil ? RDPClipboardImage.dib(from: board) : nil

        if let dib {
            dib.withUnsafeBytes { buffer in
                let base = buffer.bindMemory(to: UInt8.self).baseAddress
                macmoba_rdp_offer_clipboard(client, text, base, UInt32(buffer.count))
            }
        } else if let text {
            text.withCString { macmoba_rdp_offer_clipboard(client, $0, nil, 0) }
        }
    }

    nonisolated fileprivate func receiveRemoteFileList(_ files: [RDPRemoteFile]) {
        Task { @MainActor in
            let stamp = RDPFileClipboard.offerToPasteboard(files, transfers: self.fileTransfers)
            self.pasteboardCount = NSPasteboard.general.changeCount
            // Promises alone make drag-and-drop work, but Finder disables Paste
            // for a pasteboard that holds only promises. So fetch in the
            // background and swap in real file URLs, which ⌘V accepts.
            self.stageRemoteFiles(files, promisedAt: stamp)
        }
    }

    /// Download the copied files to a staging folder, then put their URLs on
    /// the pasteboard in place of the promises.
    private func stageRemoteFiles(_ files: [RDPRemoteFile], promisedAt stamp: Int) {
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        guard total <= RDPFileClipboard.eagerSizeLimit else {
            // Too big to pull speculatively; drag-and-drop still works, and
            // that path only transfers what is actually dropped.
            statusLine = ""
            return
        }
        stagingTask?.cancel()
        stagingTask = Task { @MainActor in
            guard let directory = RDPFileClipboard.makeStagingDirectory() else { return }
            var written: [URL] = []
            for file in files {
                if Task.isCancelled { return }
                let destination = directory
                    .appendingPathComponent((file.name as NSString).lastPathComponent)
                do {
                    try await fileTransfers.download(file, to: destination)
                    written.append(destination)
                } catch {
                    // One bad file should not sink the rest of the copy.
                    continue
                }
            }
            guard !Task.isCancelled else { return }
            if RDPFileClipboard.replacePromises(withFilesAt: written, ifChangeCountIs: stamp) {
                self.pasteboardCount = NSPasteboard.general.changeCount
            }
            self.stagingDirectories.append(directory)
        }
    }

    nonisolated fileprivate func receiveFileChunk(requestId: UInt32, data: Data?,
                                                  failed: Bool) {
        fileTransfers.deliver(requestId: requestId, data: data, failed: failed)
    }

    nonisolated fileprivate func receiveRemoteImage(_ dib: Data) {
        guard let image = RDPClipboardImage.image(fromDIB: dib) else { return }
        Task { @MainActor in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            self.pasteboardCount = NSPasteboard.general.changeCount
        }
    }

    nonisolated fileprivate func receiveRemoteClipboard(_ text: String) {
        Task { @MainActor in
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.pasteboardCount = NSPasteboard.general.changeCount
        }
    }

    func disconnect() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        // Any promise still waiting on the session has to be released, or a
        // paste started before the drop would hang forever.
        stagingTask?.cancel()
        stagingTask = nil
        fileTransfers.cancelAll()
        for directory in stagingDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        stagingDirectories.removeAll()
        spanWindows.hide()
        userClosed = true
        if let rdp { macmoba_rdp_free(OpaquePointer(rdp)) }
        rdp = nil
        route?.close()
        route = nil
    }

    private func fail(_ message: String) {
        NSLog("MacMoba RDP: connection failed — \(message)")
        state = .closed(message)
        statusLine = message
        route?.close()
        route = nil
    }

    /// Ask the server to match the pane. Only possible when it opened the
    /// display-control channel (Windows 8.1 / Server 2012 R2 and later);
    /// otherwise the desktop keeps its size and we letterbox it as before.
    private func requestResize(to size: CGSize) {
        guard let rdp, state == .connected else { return }
        // Fixed size means fixed: the pane scales the desktop to fit rather than
        // the desktop following the pane. A spanning session is likewise pinned,
        // to the bounding box of every screen — resizing it to the pane is what
        // left one screen showing pixels and the other showing black.
        guard RDPResizePolicy.allowsDynamicResize(spansDisplays: !monitors.isEmpty,
                                                  fitsWindow: config.displayMode == .fitWindow)
        else { return }
        let client = OpaquePointer(rdp)
        guard macmoba_rdp_can_resize(client) else { return }
        let desktop = RDPDesktopSize.pixels(forPoints: size, scale: container.backingScale,
                                            enforceMinimum: false,
                                            screenPixels: hostScreenPixels)
        let width = desktop.width
        let height = desktop.height
        guard width > 0, height > 0 else { return }
        if lastRequestedSize == CGSize(width: width, height: height) { return }
        lastRequestedSize = CGSize(width: width, height: height)
        macmoba_rdp_request_resize(client, Int32(width), Int32(height))
    }

    /// Monitor layout for a spanning session; empty for a single-screen one.
    private(set) var monitors: [RDPMonitor] = []
    private let spanWindows = RDPSpanWindows()
    /// The most recent frame, so a window opened later can show something
    /// immediately rather than waiting for the server to repaint.
    private var lastFrame: CGImage?

    /// True when this session was negotiated to cover every display.
    var spansDisplays: Bool { monitors.count > 1 }

    /// Start or stop covering every display. Driven by full-screen focus: the
    /// session only owns the other displays while it is full screen, and
    /// covering them at any other time would be hijacking the machine.
    ///
    /// The monitor layout is negotiated HERE rather than at connect time, over
    /// the display-control channel. That is what keeps a windowed session the
    /// size of the screen it is on.
    func setSpanning(_ on: Bool) {
        wantsSpanning = on && config.usesAllDisplays
        applySpanning()
    }

    /// Full screen is on and this session is set to use every display.
    private var wantsSpanning = false
    /// This connection was made with a monitor layout baked in, because the
    /// server would not take one while connected.
    private var connectSpanning = false

    private func applySpanning() {
        guard state == .connected, let rdp else { return }
        if wantsSpanning {
            if monitors.isEmpty {
                let layout = Self.currentMonitors()
                guard layout.count > 1 else { return }
                // Preferred route: re-lay-out the live session. Nothing is
                // interrupted and windowed sessions stay one screen big.
                if macmoba_rdp_max_monitors(OpaquePointer(rdp)) >= layout.count,
                   sendLayout(layout) {
                    monitors = layout
                } else {
                    // Older servers only accept a layout during capability
                    // exchange, so the only way to span is to connect again.
                    // The Windows session itself survives — it is the same
                    // user on the same host, so the desktop comes back as it
                    // was, with everything still open.
                    //
                    // Once only: if a connection made FOR spanning still has no
                    // layout, reconnecting again would just do the same thing
                    // forever.
                    guard !connectSpanning else { return }
                    statusLine = "Reconnecting to use every display …"
                    reconnect(spanning: true)
                    return
                }
            }
            // Whichever screen the window is actually on keeps the tab's own
            // view; every other screen gets one of these.
            spanWindows.show(monitors: monitors, hostDisplayID: hostDisplayID,
                             lastFrame: lastFrame) { [weak self] event in
                self?.send(event)
            }
            showHostSliceOnly()
        } else {
            guard !monitors.isEmpty else { return }
            spanWindows.hide()
            if connectSpanning {
                reconnect(spanning: false)
                return
            }
            monitors = []
            // Whole desktop again — and back to one screen's worth of it.
            container.sourceRect = nil
            lastRequestedSize = .zero
            requestResize(to: container.bounds.size)
        }
    }

    private func reconnect(spanning: Bool) {
        connectSpanning = spanning
        disconnect()
        connect()
    }

    private func sendLayout(_ layout: [RDPMonitor]) -> Bool {
        guard let rdp else { return false }
        var defs = layout.map {
            MacMobaRDPMonitor(x: $0.x, y: $0.y, width: $0.width, height: $0.height,
                              isPrimary: $0.isPrimary, scalePercent: $0.scalePercent)
        }
        return defs.withUnsafeMutableBufferPointer { buffer in
            macmoba_rdp_send_monitor_layout(OpaquePointer(rdp), buffer.baseAddress,
                                            Int32(buffer.count))
        }
    }

    /// Re-slice, and re-place the extra windows, after anything that can change
    /// which screen the session is looking at: the window dragged to another
    /// display, or a display plugged in or removed.
    func screenConfigurationChanged() {
        guard spansDisplays else { return }
        // Re-negotiate: a display that has been unplugged must stop being part
        // of the desktop, or the session keeps a region nothing can show.
        let layout = Self.currentMonitors()
        if layout.count > 1, layout != monitors, sendLayout(layout) {
            monitors = layout
        }
        if spanWindows.isShowing {
            spanWindows.show(monitors: monitors, hostDisplayID: hostDisplayID,
                             lastFrame: lastFrame) { [weak self] event in
                self?.send(event)
            }
        }
        showHostSliceOnly()
    }

    /// Pixel resolution of the display this session is shown on, so the desktop
    /// asked for never exceeds what can actually be displayed. Nil while there
    /// is no window yet, and deliberately nil for a spanning session, which is
    /// meant to cover more than one screen.
    private var hostScreenPixels: CGSize? {
        guard monitors.isEmpty,
              let screen = container.window?.screen ?? NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1
        return CGSize(width: screen.frame.width * scale,
                      height: screen.frame.height * scale)
    }

    /// The display the session's window is sitting on. NOT assumed to be the
    /// primary — the window can be on any screen, and assuming otherwise is
    /// what left one screen black and covered another.
    private var hostDisplayID: UInt32 {
        container.window?.screen?.displayID ?? NSScreen.main?.displayID ?? 0
    }

    /// The tab shows only the part of the desktop belonging to the screen it is
    /// on.
    ///
    /// A spanning session covers several screens' worth of desktop, and fitting
    /// all of that into one pane letterboxes it into a thin strip with most of
    /// the window black — the whole desktop is visible but nothing is usable.
    /// Showing one screen's slice makes it look and behave like an ordinary
    /// session.
    ///
    /// It has to be THIS screen's slice, not the primary's: a window on the
    /// built-in display showing the external monitor's part of the desktop
    /// looks exactly like the wrong resolution being negotiated.
    private func showHostSliceOnly() {
        let id = hostDisplayID
        let index = container.window?.screen
            .flatMap { NSScreen.screens.firstIndex(of: $0) } ?? 0
        guard let monitor = RDPMonitorLayout.monitor(in: monitors, displayID: id,
                                                     screenIndex: index) else {
            // This screen is not part of the session's layout — it was plugged
            // in after connecting, or the one this session knew about is gone.
            // The whole desktop, letterboxed, is at least all there.
            container.sourceRect = nil
            return
        }
        container.sourceRect = RDPMonitorLayout.framebufferRect(of: monitor, in: monitors)
    }

    /// This Mac's screens, as RDP monitor definitions. Empty when the layout is
    /// not one a server will accept — better a normal single-screen session
    /// than a connection refused during capability exchange.
    static func currentMonitors() -> [RDPMonitor] {
        let main = NSScreen.screens.first
        let screens = NSScreen.screens.map {
            RDPMonitorLayout.Screen(frame: $0.frame,
                                    scale: $0.backingScaleFactor,
                                    // NSScreen.screens[0] is the one with the
                                    // menu bar, which is what macOS treats as
                                    // primary and what sits at the origin.
                                    isPrimary: $0 === main,
                                    displayID: $0.displayID)
        }
        let monitors = RDPMonitorLayout.monitors(for: screens)
        guard monitors.count > 1, RDPMonitorLayout.isUsable(monitors) else { return [] }
        return monitors
    }

    private var lastRequestedSize: CGSize = .zero
    private var pasteboardTimer: Timer?
    private let fileTransfers = RDPFileTransfers()
    private var stagingTask: Task<Void, Never>?
    /// Staging folders to remove when the tab closes.
    private var stagingDirectories: [URL] = []
    private var pasteboardCount = 0

    private func send(_ event: RDPInputEvent) {
        guard let rdp, state == .connected else { return }
        let client = OpaquePointer(rdp)
        switch event {
        case .pointer(let flags, let x, let y):
            macmoba_rdp_send_pointer(client, flags, x, y)
        case .scancode(let code, let down, let extended):
            macmoba_rdp_send_scancode(client, code, down, extended)
        case .unicode(let scalar, let down):
            macmoba_rdp_send_unicode(client, scalar, down)
        }
    }

    // MARK: - Callbacks from the FreeRDP thread

    nonisolated fileprivate func handleFrame(_ pixels: UnsafePointer<UInt8>,
                                             width: Int, height: Int, stride: Int) {
        // The buffer is only valid for the duration of the callback, so build
        // the image here (which copies) before hopping to the main actor.
        let byteCount = stride * height
        let data = Data(bytes: pixels, count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let info: CGBitmapInfo = [.byteOrder32Little,
                                  CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        guard let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent) else { return }

        Task { @MainActor in
            self.lastFrame = image
            self.container.setFrame(image)
            // A spanning session shows the same frame in several windows; each
            // view crops its own monitor's slice out of it.
            self.spanWindows.setFrame(image)
            if self.title != "\(self.config.name) \(width)×\(height)" {
                self.title = "\(self.config.name) \(width)×\(height)"
            }
        }
    }

    nonisolated fileprivate func handleState(_ state: MacMobaRDPState, message: String?) {
        Task { @MainActor in
            switch state {
            case MACMOBA_RDP_STATE_CONNECTING:
                self.state = .connecting
            case MACMOBA_RDP_STATE_CONNECTED:
                self.state = .connected
                self.statusLine = ""
                // The size negotiated at connect time came from the pane before
                // layout settled; nudge the server to the real one. Ignored for
                // a spanning session, whose desktop is the monitor layout.
                self.requestResize(to: self.container.bounds.size)
                // Either finishes a reconnect that was made in order to span,
                // or spans a session that was already connected when full
                // screen started.
                self.applySpanning()
            default:
                if self.userClosed {
                    self.state = .closed("closed")
                } else {
                    let detail = self.rdp
                        .flatMap { macmoba_rdp_last_error(OpaquePointer($0)) }
                        .map { String(cString: $0) }
                    let headline = [message, detail]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " — ")
                    self.fail(headline.isEmpty ? "Disconnected." : headline)
                }
            }
        }
    }

    /// Runs on the FreeRDP thread and must answer synchronously, so the prompt
    /// is shown on the main thread and this thread waits for it — the same
    /// shape as the SSH host-key prompt.
    nonisolated fileprivate func handleCertificate(host: String, commonName: String,
                                                   fingerprint: String,
                                                   mismatch: Bool) -> Bool {
        // Already pinned and unchanged: say yes without interrupting anyone.
        // The shim answers FreeRDP with "accept once" so that FreeRDP never
        // writes its own known_hosts, which means this store is the only thing
        // standing between the user and a prompt on every single connect.
        //
        // Keyed by the *configured* target, never by what FreeRDP connected to.
        // A tunnelled session reaches 127.0.0.1 on a fresh random local port
        // every time, so pinning that would make every connection look like a
        // server we had never seen.
        let store = RDPCertificateStore.shared
        let known = store.storedFingerprint(host: config.host, port: config.port)
        if known == fingerprint { return true }

        let reason: RDPCertificatePrompt.Reason =
            known.map { .changed(from: $0) } ?? .firstTime

        let semaphore = DispatchSemaphore(value: 0)
        var accepted = false
        DispatchQueue.main.async {
            // The tab can be closed while the handshake is still in flight;
            // putting a certificate prompt on screen for a session the user has
            // already dismissed would be baffling.
            guard !MainActor.assumeIsolated({ self.userClosed }) else {
                semaphore.signal()
                return
            }
            accepted = RDPCertificatePrompt.ask(host: host, commonName: commonName,
                                                fingerprint: fingerprint,
                                                nameMismatch: mismatch, reason: reason)
            semaphore.signal()
        }
        semaphore.wait()
        if accepted {
            store.store(fingerprint: fingerprint, host: config.host, port: config.port)
        }
        return accepted
    }
}

// MARK: - C callback trampolines

private func rdpTab(_ userData: UnsafeMutableRawPointer?) -> RDPTab? {
    guard let userData else { return nil }
    return Unmanaged<RDPTab>.fromOpaque(userData).takeUnretainedValue()
}

private let onRelease: MacMobaRDPReleaseCallback = { userData in
    guard let userData else { return }
    Unmanaged<RDPTab>.fromOpaque(userData).release()
}

private let onFrame: MacMobaRDPFrameCallback = { userData, pixels, width, height, stride in
    guard let tab = rdpTab(userData), let pixels else { return }
    tab.handleFrame(pixels, width: Int(width), height: Int(height), stride: Int(stride))
}

private let onState: MacMobaRDPStateCallback = { userData, state, message in
    guard let tab = rdpTab(userData) else { return }
    tab.handleState(state, message: message.map { String(cString: $0) })
}

private let onClipboard: MacMobaRDPClipboardCallback = { userData, utf8 in
    guard let tab = rdpTab(userData), let utf8 else { return }
    tab.receiveRemoteClipboard(String(cString: utf8))
}

private let onClipboardImage: MacMobaRDPImageCallback = { userData, dib, len in
    guard let tab = rdpTab(userData), let dib, len > 0 else { return }
    tab.receiveRemoteImage(Data(bytes: dib, count: Int(len)))
}

private let onFileList: MacMobaRDPFileListCallback = { userData, names, sizes, count in
    guard let tab = rdpTab(userData), let names, let sizes, count > 0 else { return }
    let joined = String(cString: names)
    let parts = joined.components(separatedBy: "\n")
    var files: [RDPRemoteFile] = []
    for index in 0..<Int(count) where index < parts.count {
        files.append(RDPRemoteFile(index: UInt32(index),
                                   name: parts[index],
                                   size: sizes[index]))
    }
    tab.receiveRemoteFileList(files)
}

private let onFileChunk: MacMobaRDPFileChunkCallback = { userData, requestId, bytes,
                                                         len, failed in
    guard let tab = rdpTab(userData) else { return }
    let data = (bytes != nil && len > 0) ? Data(bytes: bytes!, count: Int(len)) : nil
    tab.receiveFileChunk(requestId: requestId, data: data, failed: failed)
}

private let onCertificate: MacMobaRDPCertCallback = { userData, host, commonName,
                                                      fingerprint, mismatch in
    guard let tab = rdpTab(userData) else { return false }
    return tab.handleCertificate(
        host: host.map { String(cString: $0) } ?? "",
        commonName: commonName.map { String(cString: $0) } ?? "",
        fingerprint: fingerprint.map { String(cString: $0) } ?? "",
        mismatch: mismatch)
}

// MARK: - Certificate prompt

@MainActor
enum RDPCertificatePrompt {
    /// Why we are asking. These are genuinely different situations and used to
    /// be collapsed into one: a certificate whose name simply does not match the
    /// address (every self-signed RDP server reached by IP) was announced as
    /// "the certificate has changed… something may be impersonating it".
    /// Crying wolf on the common case teaches people to click through the one
    /// warning that matters.
    enum Reason {
        /// Never seen this server before.
        case firstTime
        /// Pinned earlier, and the fingerprint is different now.
        case changed(from: String)
    }

    /// Blocking on purpose: the FreeRDP handshake is waiting on the answer.
    /// `runModal` is acceptable here for the same reason the SSH host-key
    /// prompt uses it — there is no session to steal focus from yet.
    static func ask(host: String, commonName: String, fingerprint: String,
                    nameMismatch: Bool, reason: Reason) -> Bool {
        let alert = NSAlert()
        var details = "Common name: \(commonName)\nFingerprint: \(fingerprint)"

        switch reason {
        case .firstTime:
            alert.alertStyle = .warning
            alert.messageText = "Trust the certificate for \(host)?"
            alert.informativeText =
                "RDP servers usually present a self-signed certificate, so this cannot be "
                + "checked automatically. It will be remembered for next time."
            if nameMismatch {
                // Worth stating, not worth alarming over: naming a certificate
                // after a hostname you then reach by IP is the norm.
                details += "\n\nThe name on the certificate does not match \(host). "
                    + "That is common for servers reached by IP address."
            }
        case .changed(let previous):
            alert.alertStyle = .critical
            alert.messageText = "The certificate for \(host) has changed."
            alert.informativeText =
                "You trusted a different certificate for this server before. That can mean "
                + "the server was rebuilt — or that something is impersonating it."
            details += "\nPreviously: \(previous)"
        }

        alert.informativeText += "\n\n" + details
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) {
            if case .changed = reason { alert.buttons.first?.hasDestructiveAction = true }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Input + hosting view

enum RDPInputEvent {
    case pointer(flags: UInt16, x: UInt16, y: UInt16)
    case scancode(code: UInt16, down: Bool, extended: Bool)
    case unicode(scalar: UInt16, down: Bool)
}

/// Draws the framebuffer and turns AppKit events into RDP input.
final class RDPContainerView: NSView {
    var onInput: ((RDPInputEvent) -> Void)?
    /// Called when the pane settles at a new size, so the session can follow.
    var onResize: ((CGSize) -> Void)?
    /// Called when the view ends up on a different display, so the session can
    /// show that display's part of the desktop.
    var onScreenChanged: (() -> Void)?
    /// Size we asked the server for; the frame we get back may differ.
    var requestedSize: CGSize = .zero

    private var frameImage: CGImage?

    /// The slice of the framebuffer this view shows, in desktop pixels.
    ///
    /// Nil means the whole thing, which is every single-screen session. For a
    /// session spanning displays each screen's window sets its own monitor's
    /// rectangle, so one framebuffer is shown across several windows without
    /// any of them scaling it down to fit.
    var sourceRect: CGRect? {
        didSet {
            guard sourceRect != oldValue else { return }
            if let frameImage { setFrame(frameImage) }
        }
    }

    /// What is actually put on the layer: the whole frame, or just our slice.
    private var displayedImage: CGImage? {
        guard let frameImage else { return nil }
        let desktop = CGSize(width: frameImage.width, height: frameImage.height)
        // Nil covers both "show everything" and "the slice is no longer inside
        // the desktop" — in which case the whole frame is shown rather than
        // nothing, so a layout that has drifted looks wrong instead of dead.
        guard let bounded = RDPResizePolicy.visibleSlice(sourceRect, in: desktop) else {
            return frameImage
        }
        // cropping() shares the original's data provider, so this is cheap
        // enough to do per frame.
        return frameImage.cropping(to: bounded) ?? frameImage
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    /// Layer-backed: the framebuffer is handed to CoreAnimation as layer
    /// contents rather than redrawn into a CPU backing store every frame.
    override var wantsUpdateLayer: Bool { true }

    private var trackingArea: NSTrackingArea?
    private var resizeWork: DispatchWorkItem?

    /// Resizing a window produces a continuous stream of sizes. Each one would
    /// be a round trip to the server and a full desktop re-layout, so only the
    /// size you stop at is sent.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onResize?(self.bounds.size)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Without a tracking area `mouseMoved` never fires, so the remote desktop
    /// never sees the cursor move — only clicks, and only where they land.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Configure the backing layer once. Aspect-fit is done by CoreAnimation,
    /// which matches the contentRect maths used for input.
    private func prepareLayer() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .linear
        layer.isOpaque = true
        // Without this the desktop is rendered twice and thrown away once: we
        // ask the server for backing-store pixels (see requestResize), hand
        // CoreAnimation an image that size, and a contentsScale of 1 then
        // downsamples it back to point resolution. On a Retina display that is
        // the whole difference between crisp and soft text.
        layer.contentsScale = backingScale
    }

    /// Pixels per point for whichever display the pane is currently on. Falls
    /// back to the main screen while the view has no window yet, which is when
    /// the first connection size is computed.
    var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        prepareLayer()
        // The slice this view shows depends on the display it is on, and
        // dragging a window between displays is not a resize — nothing else
        // would notice.
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        guard let window else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScreenChanged?() }
        }
        onScreenChanged?()
    }

    private var screenObserver: NSObjectProtocol?

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Dragging the window to a display with a different scale changes what a
    /// point is worth. Re-apply, and let the session re-ask the server so the
    /// desktop is native on the new screen too.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        prepareLayer()
        onResize?(bounds.size)
    }

    func setFrame(_ image: CGImage) {
        // Guard the obviously wrong: a zero-sized frame handed to CoreAnimation
        // is a good way to upset the compositor.
        guard image.width > 0, image.height > 0 else { return }
        frameImage = image
        wantsLayer = true
        prepareLayer()
        // Assigning layer contents replaces the whole surface in one step.
        // The previous approach — a fresh CGImage plus needsDisplay on every
        // frame — pushed a full CPU-drawn backing store through CoreAnimation
        // for each update, which is where a GPU-driver crash was showing up.
        layer?.contents = displayedImage
    }

    override func updateLayer() {
        prepareLayer()
        layer?.contents = displayedImage
    }

    /// Aspect-fit rectangle for the current frame, so a desktop that does not
    /// match the pane's shape is letterboxed rather than stretched.
    private var contentRect: CGRect {
        guard let displayed = displayedImage else { return bounds }
        let imageSize = CGSize(width: displayed.width, height: displayed.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// View point -> desktop pixel, undoing the aspect-fit placement.
    private func desktopPoint(_ event: NSEvent) -> (UInt16, UInt16)? {
        guard let displayed = displayedImage else { return nil }
        // No flip here: the view is isFlipped, so this point already has a
        // top-left origin — the same space contentRect is expressed in. The
        // flip in draw() is only to satisfy CGImage's bottom-left origin, and
        // undoing it here inverted Y, sending taskbar clicks to the title bar.
        let point = convert(event.locationInWindow, from: nil)
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width * CGFloat(displayed.width)
        let y = (point.y - rect.minY) / rect.height * CGFloat(displayed.height)
        guard x >= 0, y >= 0, x < CGFloat(displayed.width), y < CGFloat(displayed.height)
        else { return nil }
        // The server thinks in whole-desktop coordinates, so a view showing a
        // slice has to add its own offset back on — otherwise every window
        // sends clicks as though it were the primary monitor.
        let origin = sourceRect?.origin ?? .zero
        return (UInt16(x + origin.x), UInt16(y + origin.y))
    }

    private func sendPointer(_ event: NSEvent, flags: UInt16) {
        guard let (x, y) = desktopPoint(event) else { return }
        onInput?(.pointer(flags: flags, x: x, y: y))
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(event, flags: MACMOBA_PTR_FLAGS_MOVE)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(event, flags: MACMOBA_PTR_FLAGS_MOVE)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Position the pointer first. Windows tracks hover state separately
        // from clicks, and a button-down at a position it has not seen the
        // cursor move to is ignored by some controls.
        sendPointer(event, flags: MACMOBA_PTR_FLAGS_MOVE)
        sendPointer(event, flags: MACMOBA_PTR_FLAGS_DOWN | MACMOBA_PTR_FLAGS_BUTTON1)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointer(event, flags: MACMOBA_PTR_FLAGS_BUTTON1)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendPointer(event, flags: MACMOBA_PTR_FLAGS_DOWN | MACMOBA_PTR_FLAGS_BUTTON2)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointer(event, flags: MACMOBA_PTR_FLAGS_BUTTON2)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = desktopPoint(event) else { return }
        let steps = Int(abs(event.scrollingDeltaY).rounded(.up))
        guard steps > 0 else { return }
        var flags = MACMOBA_PTR_FLAGS_WHEEL | 0x0078 // 120 = one notch
        if event.scrollingDeltaY < 0 { flags |= MACMOBA_PTR_FLAGS_WHEEL_NEGATIVE }
        for _ in 0..<min(steps, 5) {
            onInput?(.pointer(flags: flags, x: x, y: y))
        }
    }

    override func keyDown(with event: NSEvent) {
        sendKey(event, down: true)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, down: false)
    }

    private var activeModifiers: NSEvent.ModifierFlags = []

    /// Modifiers arrive as flag changes, not key events. Without forwarding
    /// them the remote side never sees Ctrl or Alt held, so no shortcut works —
    /// including the Ctrl+V people reach for the moment clipboard sharing
    /// exists. Command is mapped to the Windows key.
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let mapping: [(NSEvent.ModifierFlags, UInt16, Bool)] = [
            (.shift,   0x2A, false),  // left shift
            (.control, 0x1D, false),  // left control
            (.option,  0x38, false),  // left alt
            (.command, 0x5B, true),   // left Windows key
        ]
        for (flag, code, extended) in mapping {
            let nowDown = flags.contains(flag)
            let wasDown = activeModifiers.contains(flag)
            if nowDown != wasDown {
                onInput?(.scancode(code: code, down: nowDown, extended: extended))
            }
        }
        activeModifiers = flags.intersection([.shift, .control, .option, .command])
    }

    /// Special keys go as scancodes. Ordinary typing goes as Unicode, which
    /// sidesteps modelling the whole keyboard layout — but a shortcut must be
    /// a scancode, because the server matches Ctrl+V on the physical key, not
    /// on the character it would have produced.
    private func sendKey(_ event: NSEvent, down: Bool) {
        if let (code, extended) = RDPScancodes.map(macKeyCode: event.keyCode) {
            onInput?(.scancode(code: code, down: down, extended: extended))
            return
        }
        let isShortcut = !event.modifierFlags
            .intersection([.command, .control, .option]).isEmpty
        if isShortcut {
            if let code = RDPScancodes.character(macKeyCode: event.keyCode) {
                onInput?(.scancode(code: code, down: down, extended: false))
            }
            return
        }
        guard let characters = event.charactersIgnoringModifiers,
              let fallback = characters.unicodeScalars.first,
              fallback.value <= 0xFFFF else { return }
        let typed = event.characters?.unicodeScalars.first ?? fallback
        guard typed.value <= 0xFFFF else { return }
        onInput?(.unicode(scalar: UInt16(typed.value), down: down))
    }
}

/// The handful of keys that have no useful Unicode form.
enum RDPScancodes {
    /// macOS virtual key code -> RDP set-1 scancode, for the main typing area.
    /// Only needed while a modifier is held; plain typing goes as Unicode.
    private static let characterMap: [UInt16: UInt16] = [
        0x00: 0x1E, 0x01: 0x1F, 0x02: 0x20, 0x03: 0x21, 0x04: 0x23, // a s d f h
        0x05: 0x22, 0x06: 0x2C, 0x07: 0x2D, 0x08: 0x2E, 0x09: 0x2F, // g z x c v
        0x0B: 0x30, 0x0C: 0x10, 0x0D: 0x11, 0x0E: 0x12, 0x0F: 0x13, // b q w e r
        0x10: 0x15, 0x11: 0x14, 0x1F: 0x18, 0x20: 0x16, 0x22: 0x17, // y t o u i
        0x23: 0x19, 0x25: 0x26, 0x26: 0x24, 0x28: 0x25, 0x2D: 0x31, // p l j k n
        0x2E: 0x32,                                                 // m
        0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x17: 0x06, // 1 2 3 4 5
        0x16: 0x07, 0x1A: 0x08, 0x1C: 0x09, 0x19: 0x0A, 0x1D: 0x0B, // 6 7 8 9 0
        0x31: 0x39,                                                 // space
    ]

    static func character(macKeyCode: UInt16) -> UInt16? {
        characterMap[macKeyCode]
    }

    static func map(macKeyCode: UInt16) -> (UInt16, Bool)? {
        switch macKeyCode {
        case 36: return (0x1C, false)   // Return
        case 76: return (0x1C, true)    // keypad Enter
        case 48: return (0x0F, false)   // Tab
        case 51: return (0x0E, false)   // Backspace
        case 53: return (0x01, false)   // Escape
        case 117: return (0x53, true)   // Delete (forward)
        case 123: return (0x4B, true)   // Left
        case 124: return (0x4D, true)   // Right
        case 125: return (0x50, true)   // Down
        case 126: return (0x48, true)   // Up
        case 115: return (0x47, true)   // Home
        case 119: return (0x4F, true)   // End
        case 116: return (0x49, true)   // Page Up
        case 121: return (0x51, true)   // Page Down
        default: return nil
        }
    }
}

struct RDPHostView: NSViewRepresentable {
    let tab: RDPTab

    /// Same rule as the VNC and web hosts: SwiftUI owns a plain host, and the
    /// one live surface is moved into whichever host is on screen. Returning
    /// the shared container directly breaks when the pane moves between tabs.
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        attach(to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        attach(to: host)
    }

    private func attach(to host: NSView) {
        let container = tab.container
        guard container.superview !== host else { return }
        container.removeFromSuperview()
        container.frame = host.bounds
        container.autoresizingMask = [.width, .height]
        host.addSubview(container)
        DispatchQueue.main.async { container.window?.makeFirstResponder(container) }
    }
}

struct RDPPaneView: View {
    @ObservedObject var tab: RDPTab

    var body: some View {
        RDPHostView(tab: tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .overlay {
                if tab.state != .connected {
                    VStack(spacing: 10) {
                        if case .closed = tab.state {
                            Text(tab.statusLine.isEmpty ? "Disconnected" : tab.statusLine)
                                .foregroundStyle(.white.opacity(0.85))
                                .multilineTextAlignment(.center)
                            HStack {
                                Button { tab.connect() } label: {
                                    Label("Reconnect", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.borderedProminent)
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([RDPTab.logURL])
                                } label: {
                                    Label("Show Log", systemImage: "doc.text.magnifyingglass")
                                }
                            }
                            Text("FreeRDP's own log says why: \(RDPTab.logURL.lastPathComponent)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        } else {
                            ProgressView().controlSize(.small)
                            Text(tab.statusLine).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(20)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                }
            }
    }
}


/// Windows clipboard images are packed DIBs — a .bmp file without its 14-byte
/// file header. Adding or stripping that header lets AppKit do the actual
/// decoding and encoding, rather than hand-rolling BITMAPINFOHEADER parsing.
enum RDPClipboardImage {
    private static let fileHeaderSize = 14

    static func image(fromDIB dib: Data) -> NSImage? {
        guard dib.count > 4 else { return nil }
        var bmp = Data(capacity: dib.count + fileHeaderSize)
        bmp.append(contentsOf: [0x42, 0x4D])                       // "BM"
        appendUInt32(&bmp, UInt32(dib.count + fileHeaderSize))     // file size
        appendUInt32(&bmp, 0)                                      // reserved
        // Pixel data starts after the file header, the info header, and any
        // palette. The info header's own size field says how long it is.
        let headerSize = dib.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        appendUInt32(&bmp, UInt32(fileHeaderSize) + headerSize + paletteBytes(dib, headerSize))
        bmp.append(dib)
        return NSImage(data: bmp)
    }

    static func dib(from board: NSPasteboard) -> Data? {
        guard let image = NSImage(pasteboard: board),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let bmp = rep.representation(using: .bmp, properties: [:]),
              bmp.count > fileHeaderSize else { return nil }
        // Strip the file header; the DIB is everything after it.
        return bmp.subdata(in: fileHeaderSize..<bmp.count)
    }

    /// Palette size for the indexed formats. True-colour DIBs have none, but
    /// getting this wrong shifts every pixel, so it is worth computing.
    private static func paletteBytes(_ dib: Data, _ headerSize: UInt32) -> UInt32 {
        guard headerSize >= 40, dib.count >= 16 else { return 0 }
        let bitCount = dib.subdata(in: 14..<16).withUnsafeBytes {
            $0.loadUnaligned(as: UInt16.self)
        }
        guard bitCount <= 8 else { return 0 }
        var used: UInt32 = 0
        if dib.count >= 36 {
            used = dib.subdata(in: 32..<36).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        if used == 0 { used = 1 << UInt32(bitCount) }
        return used * 4
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}


private extension Array where Element == String {
    /// Run `body` with a C array of pointers into temporary copies of these
    /// strings. Everything is freed on the way out.
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
        guard !isEmpty else { return body(nil) }
        var copies: [UnsafeMutablePointer<CChar>?] = map { strdup($0) }
        defer { copies.forEach { free($0) } }
        return copies.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(
                to: UnsafePointer<CChar>?.self, capacity: buffer.count
            ) { body($0) }
        }
    }
}

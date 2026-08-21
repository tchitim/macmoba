// One VNC tab = one RoyalVNC connection + its framebuffer view.
//
// Shaped deliberately like TerminalTab: same State enum, same connect/
// disconnect lifecycle, so SessionTab and the tab chips do not need to care
// which protocol a tab speaks.

import AppKit
import Foundation
import MacMobaCore
import RoyalVNCKit
import SwiftUI

@MainActor
final class VNCTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let config: SessionConfig

    @Published var state: TerminalTab.State = .connecting
    @Published var title: String
    /// Shown over the framebuffer while connecting or after a failure.
    @Published var statusLine: String = ""

    /// Stable container: the framebuffer view only exists once the server has
    /// told us the screen size, but SwiftUI needs a view to host immediately.
    let container = VNCContainerView()

    private var connection: VNCConnection?
    private var route: RemoteDesktopRoute?
    private weak var app: AppState?
    /// The session with its password-manager reference resolved, set at connect
    /// so the credential delegate hands the VNC server a literal password.
    private var resolvedConfig: SessionConfig?
    private var userClosed = false
    /// Kept so the framebuffer view can be rebuilt. The library binds a view to
    /// one framebuffer at construction — which is why a resize builds a new
    /// one rather than poking the old — and moving between tabs turns out to
    /// need the same treatment.
    private var framebuffer: VNCFramebuffer?
    /// Enough state to answer "why is it black" without guessing: whether
    /// frames are still arriving, whether the view was rebuilt, and what the
    /// view actually looked like when it was.
    private(set) var framebufferUpdates = 0
    private(set) var rebuilds = 0
    private(set) var lastRebuildNote = "never"

    var screenReport: String {
        let fb = container.framebufferView
        let size = framebuffer.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "none"
        return """
        frames received: \(framebufferUpdates)
        framebuffer: \(size) · connection: \(connection == nil ? "none" : "live") · state: \(state)
        container: bounds \(Int(container.bounds.width))×\(Int(container.bounds.height))         · superview \(container.superview == nil ? "none" : "yes")         · window \(container.window == nil ? "none" : "yes")
        framebuffer view: \(fb == nil ? "none" : "present")         · bounds \(Int(fb?.bounds.width ?? 0))×\(Int(fb?.bounds.height ?? 0))         · window \(fb?.window == nil ? "none" : "yes")         · layer contents \(fb?.layer?.contents == nil ? "empty" : "set")
        rebuilds: \(rebuilds) · last: \(lastRebuildNote)
        """
    }

    init(config: SessionConfig, app: AppState) {
        self.config = config
        self.app = app
        self.title = config.name
        super.init()
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
                // Resolve op:// / cmd: references — the gateway chain's logins
                // and the VNC server's own password.
                let resolvedChain = try await SecretResolver.resolve(sessions: chain)
                self.resolvedConfig = try await SecretResolver.resolve(session: config)
                let route = try await RemoteDesktopRoute.open(
                    target: config, via: resolvedChain.last,
                    viaHops: resolvedChain.dropLast().map { $0 },
                    hostKeys: app?.hostKeyVerification)
                self.route = route
                let settings = VNCConnection.Settings(
                    isDebugLoggingEnabled: false,
                    hostname: route.host,
                    port: UInt16(route.port),
                    isShared: true,
                    isScalingEnabled: true,
                    useDisplayLink: true,
                    // Send ⌘-shortcuts to the remote Mac rather than keeping
                    // them here. With the "if not in use locally" mode the
                    // library forwards NO command shortcut at all, and ⌘V then
                    // hits our own Edit ▸ Paste — which the framebuffer view
                    // does not implement, so the keystroke simply vanished.
                    // Controlling a remote desktop means ⌘V, ⌘C and friends
                    // belong to it, which is what Screen Sharing itself does.
                    // (⌘Q and the screenshot keys are system hotkeys and stay
                    // local; forwarding those needs Accessibility permission.)
                    inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
                    isClipboardRedirectionEnabled: true,
                    colorDepth: .depth24Bit,
                    // Client preference order. copyRect first (it is free when
                    // the server can use it), then the compressed encodings,
                    // with raw last as the always-supported fallback.
                    frameEncodings: [.copyRect, .zrle, .zlib, .hextile, .coRRE, .rre, .raw]
                )
                let connection = VNCConnection(settings: settings,
                                               logger: app?.vncLogger ?? VNCDiagnosticLogger(),
                                               context: nil)
                connection.delegate = self
                self.connection = connection
                connection.connect()
            } catch {
                self.fail("Could not open the tunnel: \(error)")
            }
        }
    }

    /// Build a fresh framebuffer view for the live connection.
    ///
    /// Used after the pane moves to another tab. The old view stops painting
    /// there: its display link is started only from `viewDidMoveToWindow` and
    /// only when a window is already present, so re-parenting can leave it
    /// with a live connection and nothing driving the screen. A new view goes
    /// through the same construction the first one did.
    func rebuildFramebufferView() {
        rebuilds += 1
        guard let connection, let framebuffer else {
            lastRebuildNote = "skipped — \(self.connection == nil ? "no connection" : "no framebuffer")"
            return
        }
        lastRebuildNote = "container \(Int(container.bounds.width))×\(Int(container.bounds.height))"
            + " · window \(container.window == nil ? "none" : "yes")"
        let view = VNCCAFramebufferView(frame: container.bounds,
                                        framebuffer: framebuffer,
                                        connection: connection)
        container.install(view)
        container.window?.makeFirstResponder(view)
        // A new view starts empty and only fills in when the server sends the
        // next frame — which, on a still desktop, may be a long wait that looks
        // exactly like the bug this fixes. Hand it what we already have.
        view.connection(connection, didUpdateFramebuffer: framebuffer,
                        x: 0, y: 0,
                        width: UInt16(framebuffer.size.width),
                        height: UInt16(framebuffer.size.height))
    }

    func disconnect() {
        userClosed = true
        connection?.disconnect()
        connection = nil
        route?.close()
        route = nil
    }

    private func fail(_ message: String) {
        state = .closed(message)
        statusLine = message
        route?.close()
        route = nil
    }
}

// MARK: - RoyalVNC delegate

extension VNCTab: VNCConnectionDelegate {
    nonisolated func connection(_ connection: VNCConnection,
                                stateDidChange connectionState: VNCConnection.ConnectionState) {
        let status = connectionState.status
        let error = connectionState.error
        Task { @MainActor in
            switch status {
            case .connecting, .disconnecting:
                self.state = .connecting
            case .connected:
                self.state = .connected
                self.statusLine = ""
            case .disconnected:
                // A disconnect we asked for is not a failure worth reporting.
                if self.userClosed {
                    self.state = .closed("closed")
                } else {
                    self.fail(error.map { "Disconnected: \($0.localizedDescription)" }
                              ?? "Disconnected.")
                }
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                credentialFor authenticationType: VNCAuthenticationType,
                                completion: @escaping (VNCCredential?) -> Void) {
        Task { @MainActor in
            let password = (self.resolvedConfig ?? self.config).password ?? ""
            // Some servers (macOS Screen Sharing, RealVNC) want a username too;
            // classic VNC auth is password-only.
            if authenticationType.requiresUsername {
                completion(VNCUsernamePasswordCredential(username: self.config.username,
                                                         password: password))
            } else {
                completion(VNCPasswordCredential(password: password))
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didCreateFramebuffer framebuffer: VNCFramebuffer) {
        Task { @MainActor in
            self.framebuffer = framebuffer
            let view = VNCCAFramebufferView(frame: .zero,
                                            framebuffer: framebuffer,
                                            connection: connection)
            self.container.install(view)
            self.title = "\(self.config.name) \(Int(framebuffer.size.width))×\(Int(framebuffer.size.height))"
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didResizeFramebuffer framebuffer: VNCFramebuffer) {
        // The view binds to one framebuffer at construction, so a resize means
        // building a fresh one rather than poking the old.
        Task { @MainActor in
            self.framebuffer = framebuffer
            let view = VNCCAFramebufferView(frame: self.container.bounds,
                                            framebuffer: framebuffer,
                                            connection: connection)
            self.container.install(view)
            self.title = "\(self.config.name) \(Int(framebuffer.size.width))×\(Int(framebuffer.size.height))"
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didUpdateFramebuffer framebuffer: VNCFramebuffer,
                                x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        Task { @MainActor in
            self.framebufferUpdates += 1
            self.container.framebufferView?.connection(
                connection, didUpdateFramebuffer: framebuffer,
                x: x, y: y, width: width, height: height)
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didUpdateCursor cursor: VNCCursor) {
        Task { @MainActor in
            self.app?.vncCursorDiagnostics.record(cursor)
            self.app?.vncKeyboard.remoteCursorChanged(cursor)
            self.container.framebufferView?.connection(connection, didUpdateCursor: cursor)
        }
    }
}

// MARK: - Hosting view

/// Holds the framebuffer view once it exists and keeps it pinned to our bounds.
/// Same job as PaneContainerView on the terminal side.
final class VNCContainerView: NSView {
    private(set) var framebufferView: VNCCAFramebufferView?

    func install(_ view: VNCCAFramebufferView) {
        framebufferView?.removeFromSuperview()
        framebufferView = view
        view.frame = bounds
        addSubview(view)
        window?.makeFirstResponder(view)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        framebufferView?.frame = CGRect(origin: .zero, size: newSize)
    }

    override func layout() {
        super.layout()
        framebufferView?.frame = bounds
    }
}

struct VNCHostView: NSViewRepresentable {
    let tab: VNCTab

    /// A fresh host each time, with the one framebuffer moved into whichever
    /// host is currently on screen — the same rule the web tab already
    /// follows. Handing SwiftUI the shared container itself worked until the
    /// pane moved: breaking a split apart builds a new representable, and the
    /// old one's teardown pulled the container out of the new hierarchy on its
    /// way out, leaving a live connection drawing into nothing. That is what a
    /// black remote desktop after ungrouping was.
    func makeNSView(context: Context) -> NSView {
        let host = SurfaceHostView()
        host.onWindowChange = { [weak host] in
            guard let host else { return }
            attach(to: host)
        }
        attach(to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        attach(to: host)
    }

    private func attach(to host: NSView) {
        let container = tab.container
        SurfaceHosting.attach(container, to: host)
        guard container.superview === host, container.window != nil else { return }
        // The moved view keeps a live connection but stops painting, so it is
        // replaced rather than nudged — the same answer the library gives for
        // a resize, and for the same reason: a framebuffer view is bound to
        // its framebuffer and its window at construction.
        DispatchQueue.main.async { tab.rebuildFramebufferView() }
    }
}

/// The VNC tab's content: the framebuffer, with a status overlay while it is
/// connecting or after it has dropped.
struct VNCPaneView: View {
    @ObservedObject var tab: VNCTab
    @EnvironmentObject var app: AppState

    var body: some View {
        VNCHostView(tab: tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .overlay(alignment: .top) { CaptureHint(bridge: app.vncKeyboard) }
            .overlay {
                if tab.state != .connected {
                    VStack(spacing: 10) {
                        if case .closed = tab.state {
                            Text(tab.statusLine.isEmpty ? "Disconnected" : tab.statusLine)
                                .foregroundStyle(.white.opacity(0.85))
                                .multilineTextAlignment(.center)
                            Button {
                                tab.connect()
                            } label: {
                                Label("Reconnect", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                            Text(tab.statusLine)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(20)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                }
            }
    }
}

/// Says how to get the keyboard back. Capturing input takes ⌘Tab and the rest
/// of this Mac's shortcuts away from it, so the way out has to be on screen —
/// it fades once you have seen it, and comes back whenever input is captured
/// again.
private struct CaptureHint: View {
    @ObservedObject var bridge: VNCKeyboardBridge
    @State private var showing = false

    var body: some View {
        Group {
            if showing {
                Label("Input captured — \(bridge.releaseHint)", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.top, 10)
                    .transition(.opacity)
            } else if bridge.isGrabbed {
                // What is left after the sentence fades. While input is
                // captured the local cursor is parked and hidden, so clicking
                // the sidebar does nothing — the click goes to the remote.
                // Without a standing sign, the app looks broken rather than
                // busy, which is exactly how it was reported.
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(5)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(.top, 6)
                    .help("Input is captured — \(bridge.releaseHint)")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showing)
        .onChange(of: bridge.isGrabbed) { grabbed in
            guard grabbed else { return showing = false }
            showing = true
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if bridge.isGrabbed { showing = false }
            }
        }
    }
}

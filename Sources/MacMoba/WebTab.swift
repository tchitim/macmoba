// A web page reached through an SSH session.
//
// The reason this exists: plenty of internal pages — a Jenkins, a Cockpit, a
// switch's admin UI — are only reachable from inside the network. The usual
// answer is `ssh -D` plus configuring a whole browser to use the proxy, which
// then sends ALL your browsing through the bastion. Here the tunnel belongs to
// one tab and nothing else on the Mac is affected.

import AppKit
import Combine
import MacMobaCore
import SwiftUI
import WebKit

@MainActor
final class WebTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let config: SessionConfig

    @Published var state: TerminalTab.State = .connecting
    @Published var title: String
    @Published var statusLine = ""
    @Published var addressText = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    /// The SSH session carrying the traffic, for the "via" label.
    @Published private(set) var proxyDescription: String?
    /// True when macOS is connecting directly despite the tunnel being up.
    @Published private(set) var bypassesTunnel = false
    private var tunnelWarning = ""

    private weak var app: AppState?
    private var forward: DynamicForward?
    /// A certificate decision waiting to be put to the user. WebKit issues
    /// several challenges for one navigation, so without this the same server
    /// would stack several identical alerts.
    private var certificateDecisionPending = false
    /// Set while we cancel a challenge on purpose, so the resulting
    /// "cancelled" error is not reported as if the load had gone wrong.
    private var cancelledForCertificatePrompt = false
    private var observations: [NSKeyValueObservation] = []
    private(set) var webView: WKWebView?

    init(config: SessionConfig, app: AppState) {
        self.config = config
        self.app = app
        self.title = config.name
        super.init()
    }

    /// Build the web view, starting a SOCKS proxy first when the session goes
    /// through SSH.
    func start() {
        guard webView == nil else { return }
        state = .connecting
        let chain = app?.jumpChain(for: config) ?? []
        let via = chain.last
        Task {
            var proxyPort: Int?
            if let via {
                statusLine = "Opening a tunnel through \(via.name) …"
                do {
                    // Port 0: the OS picks a free one, so several web tabs can
                    // each have their own tunnel.
                    let tunnel = TunnelConfig(
                        id: "web-\(config.id)-\(id.uuidString)",
                        name: "\(config.name) via \(via.name)",
                        type: "dynamic", sessionId: via.id,
                        bindHost: "127.0.0.1", bindPort: 0,
                        targetHost: "", targetPort: 0)
                    // Resolve op:// / cmd: on the SSH gateway chain.
                    let resolvedVia = try await SecretResolver.resolve(session: via)
                    let resolvedHops = try await SecretResolver.resolve(
                        sessions: chain.dropLast().map { $0 })
                    let forward = try await DynamicForward.start(
                        config: tunnel, session: resolvedVia, via: resolvedHops,
                        hostKeys: app?.hostKeyVerification)
                    self.forward = forward
                    proxyPort = forward.localPort
                    self.proxyDescription = via.name
                } catch {
                    self.state = .closed("Could not open the tunnel: "
                                         + error.localizedDescription)
                    self.statusLine = ""
                    return
                }
            }
            self.makeWebView(proxyPort: proxyPort)
            self.state = .connected
            self.statusLine = ""
            if let url = WebAddress.url(for: config.webURL ?? config.host) {
                self.load(url)
            }
        }
    }

    private func makeWebView(proxyPort: Int?) {
        let configuration = WKWebViewConfiguration()
        // A data store of its own, and a PERSISTENT one: see WebDataStoreID.
        // Non-persistent means no cache, so a heavy site re-downloads its whole
        // bundle over the tunnel every single time the tab is opened.
        if #available(macOS 14.0, *) {
            configuration.websiteDataStore =
                WKWebsiteDataStore(forIdentifier: WebDataStoreID.identifier(for: config.id))
        } else {
            configuration.websiteDataStore = .nonPersistent()
        }

        let controller = WKUserContentController()
        // See WebClipboardBridge: an http page has no navigator.clipboard, so
        // the site's own copy buttons do nothing until this puts it back.
        controller.add(self, name: WebClipboardBridge.handlerName)
        controller.addUserScript(WKUserScript(source: WebClipboardBridge.script,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        configuration.userContentController = controller

        if let proxyPort {
            if #available(macOS 14.0, *) {
                let endpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                  port: NWEndpoint.Port(integerLiteral:
                                                                        UInt16(proxyPort)))
                configuration.websiteDataStore.proxyConfigurations =
                    [ProxyConfiguration(socksv5Proxy: endpoint)]
            } else {
                // Without per-view proxy support the page would silently load
                // DIRECTLY, which on a private network means it simply fails —
                // and looks like the tunnel is broken rather than unsupported.
                statusLine = "Routing a web tab through SSH needs macOS 14 or later."
            }
        }

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        webView = view

        observations = [
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in
                    if let url = view.url { self?.addressText = WebAddress.display(url) }
                }
            },
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let pageTitle = view.title ?? ""
                    self.title = pageTitle.isEmpty ? self.config.name : pageTitle
                }
            },
        ]
    }

    func load(_ url: URL) {
        addressText = WebAddress.display(url)
        checkTheTunnelIsActuallyUsed(for: url)
        webView?.load(URLRequest(url: url))
    }

    /// macOS skips the proxy for loopback and for the Mac's own subnet, and
    /// there is no way to ask it not to. Rather than let the "via" label claim
    /// a tunnel that is not being used, say what is really happening.
    private func checkTheTunnelIsActuallyUsed(for url: URL) {
        guard proxyDescription != nil, let host = url.host else {
            bypassesTunnel = false
            return
        }
        bypassesTunnel = ProxyBypass.sendsDirect(host: host,
                                                 localNetworks: ProxyBypass.localNetworks())
        if bypassesTunnel {
            tunnelWarning = "\(host) is on this Mac's own network, so macOS connects to "
                + "it directly — this page is not going through the tunnel."
            statusLine = tunnelWarning
        }
    }

    /// Load whatever is in the address bar.
    func submitAddress() {
        // No search engine on purpose: an internal hostname must never be sent
        // to one. See WebAddress.
        guard let url = WebAddress.url(for: addressText) else {
            statusLine = "That does not look like an address."
            return
        }
        statusLine = ""
        load(url)
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    func disconnect() {
        observations.removeAll()
        webView?.stopLoading()
        // The content controller holds this object, so the tab would outlive
        // its own window without this.
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: WebClipboardBridge.handlerName)
        webView = nil
        forward?.stop()
        forward = nil
        state = .closed("closed")
    }
}

extension WebTab: WKScriptMessageHandler {
    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == WebClipboardBridge.handlerName,
              let text = message.body as? String
        else { return }
        Task { @MainActor in self.copyToPasteboard(text) }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // A copy button that works but looks like it did nothing is barely
        // better than one that does nothing, so say it happened.
        let notice = "Copied \(text.count) character\(text.count == 1 ? "" : "s")"
        statusLine = notice
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if statusLine == notice { statusLine = bypassesTunnel ? tunnelWarning : "" }
        }
    }
}

extension WebTab: WKNavigationDelegate {
    /// Self-signed and private-CA certificates are the norm on the internal
    /// consoles this tab exists to reach, and WebKit refuses them with no way
    /// through. So take the decision the same way the SSH host key and the RDP
    /// certificate are taken: evaluate normally first, and only when the system
    /// says no, show the fingerprint once and pin it. A pinned certificate that
    /// later changes is never waved through — that is the case the whole
    /// mechanism is for.
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                               URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let store = WebCertificateStore.shared
        let host = space.host
        let port = space.port
        let identity = WebCertificate.identity(of: trust)
        let action = WebCertificateTrust.action(
            systemTrusted: WebCertificate.isSystemTrusted(trust),
            stored: store.storedFingerprint(host: host, port: port),
            offered: identity?.fingerprint)

        let outcome: WebCertificateTrust.Outcome
        switch action {
        case .useSystemDefault:
            completionHandler(.performDefaultHandling, nil)
            return
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        case .decline:
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        case .declineThenAsk(let reason):
            outcome = reason
        }
        guard let identity else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Answer WebKit *now*. A challenge that is left open while a person
        // reads an alert is abandoned: measured against a real self-signed
        // server, answering even 0.2s late leaves the navigation dead — which
        // is why trusting the certificate appeared to do nothing at all. So
        // decline this attempt immediately, ask afterwards, and reload; the
        // reload finds the pin and answers straight away.
        cancelledForCertificatePrompt = true
        completionHandler(.cancelAuthenticationChallenge, nil)

        guard !certificateDecisionPending else { return }
        certificateDecisionPending = true
        let url = webView.url ?? WebAddress.url(for: addressText)

        // Off this turn of the run loop, so the alert cannot run inside the
        // delegate callback WebKit is still unwinding.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.certificateDecisionPending = false }
            let accepted = WebCertificatePrompt.ask(host: host,
                                                    commonName: identity.commonName,
                                                    fingerprint: identity.fingerprint,
                                                    reason: outcome)
            guard accepted else {
                self.statusLine = "Certificate for \(host) was not trusted."
                return
            }
            store.store(fingerprint: identity.fingerprint, host: host, port: port)
            self.statusLine = ""
            if let url { self.load(url) } else { self.webView?.reload() }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        // Our own doing: we cancelled the challenge so the certificate could be
        // put to the user. Saying "cancelled" here would report the mechanism
        // working as if it had failed.
        if cancelledForCertificatePrompt {
            cancelledForCertificatePrompt = false
            if (error as NSError).code == NSURLErrorCancelled { return }
        }
        statusLine = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusLine = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A finished load must not wipe the warning that it went direct.
        if !bypassesTunnel { statusLine = "" }
    }
}

// MARK: - Views

struct WebPaneView: View {
    @ObservedObject var tab: WebTab

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear { tab.start() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { tab.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
            Button { tab.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
            Button { tab.reload() } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
            }
            TextField("Address", text: $tab.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit { tab.submitAddress() }
            if let via = tab.proxyDescription {
                if tab.bypassesTunnel {
                    Label("not via \(via)", systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("This address is on your own network, so macOS connects "
                              + "directly instead of through \(via)")
                } else {
                    Label("via \(via)", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Traffic for this tab goes through the \(via) SSH session")
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        switch tab.state {
        case .connecting:
            VStack(spacing: 8) {
                ProgressView()
                Text(tab.statusLine.isEmpty ? "Starting…" : tab.statusLine)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .closed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.title)
                Text(message).multilineTextAlignment(.center).padding(.horizontal)
                Button("Try Again") { tab.start() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected:
            ZStack(alignment: .bottom) {
                WebViewHost(tab: tab)
                if !tab.statusLine.isEmpty {
                    Text(tab.statusLine)
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
        }
    }
}

struct WebViewHost: NSViewRepresentable {
    @ObservedObject var tab: WebTab

    func makeNSView(context: Context) -> NSView {
        let container = SurfaceHostView()
        container.onWindowChange = { [weak container] in
            guard let container else { return }
            attach(to: container)
        }
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    /// Same self-healing rule as the terminal panes: one web view, and it
    /// belongs to whichever container is currently on screen.
    private func attach(to container: NSView) {
        guard let webView = tab.webView else { return }
        SurfaceHosting.attach(webView, to: container)
    }
}

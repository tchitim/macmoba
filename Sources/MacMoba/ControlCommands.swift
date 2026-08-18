// The app side of the control socket (cmux-style scriptability): what each
// `macmoba` CLI command actually does to the running app. The socket, framing
// and token check live in MacMobaCore.ControlServer; this file is only the
// command table, so adding a command is one case here and nothing else.

import AppKit
import Foundation
import MacMobaCore

extension AppState {
    /// Start listening. Called once from init; sessions appear in `list-tabs`
    /// as the vault unlocks and tabs open.
    func startControlServer() {
        let dir = Self.dataDirectory
        let socketPath = dir.appendingPathComponent("control.sock").path
        // A fresh token per launch, readable only by this user. The CLI picks
        // it up from the file; anything with yesterday's token fails closed.
        let token = (0..<32).map { _ in "0123456789abcdef".randomElement()! }
            .map(String.init).joined()
        let tokenFile = dir.appendingPathComponent("control.token")
        try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: tokenFile.path)
        Task { [weak self] in
            let server = try? await ControlServer.start(socketPath: socketPath,
                                                        token: token) { request in
                await MainActor.run {
                    self?.handleControl(request)
                        ?? .failure("MacMoba is shutting down")
                }
            }
            await MainActor.run { self?.controlServer = server }
        }
    }

    // MARK: - command table

    private func handleControl(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case "ping":
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                as? String ?? "dev"
            return .success(json: jsonString(["app": "MacMoba", "version": version]))

        case "list-tabs":
            let items: [[String: Any]] = allTabs.enumerated().map { index, tab in
                [
                    "index": index,
                    "title": tab.title,
                    "kind": tab.isLocal ? "local" : tab.kind.rawValue,
                    "state": stateName(tab),
                    "attention": tab.attentionCount > 0,
                ]
            }
            return .success(json: jsonString(items))

        case "open":
            guard let name = request.args["session"], !name.isEmpty else {
                return .failure("open needs a session name")
            }
            guard let session = data.sessions.first(where: { $0.name == name })
                    ?? data.sessions.first(where: {
                        $0.name.localizedCaseInsensitiveContains(name)
                    }) else {
                return .failure("no saved session matches “\(name)”")
            }
            guard let window = windows.first else {
                return .failure("no window open (is the vault unlocked?)")
            }
            window.openTab(for: session)
            return .success(json: jsonString(["opened": session.name]))

        case "open-url":
            // The browser-surface command: an agent opens a page in a real web
            // tab — optionally tunnelled through a named SSH session's SOCKS
            // proxy, which is how a page only a bastion can see gets shown.
            guard unlocked else { return .failure("vault is locked") }
            guard var url = request.args["url"], !url.isEmpty else {
                return .failure("open-url needs a URL")
            }
            if !url.contains("://") { url = "https://" + url }
            guard let window = windows.first else { return .failure("no window open") }
            var via: String?
            if let viaName = request.args["via"], !viaName.isEmpty {
                guard let jump = data.sessions.first(where: {
                    $0.sessionKind == .ssh && $0.name.localizedCaseInsensitiveContains(viaName)
                }) else {
                    return .failure("no SSH session matches “\(viaName)” to tunnel through")
                }
                via = jump.id
            }
            var config = SessionConfig(
                name: URL(string: url)?.host ?? url,
                host: "", username: "",
                kind: SessionKind.web.rawValue)
            config.webURL = url
            config.proxyJump = via
            window.openTab(for: config)
            return .success(json: jsonString(["opened": url]))

        case "send":
            guard let text = request.args["text"], !text.isEmpty else {
                return .failure("send needs text")
            }
            switch resolvePane(request.args["tab"]) {
            case .failure(let message): return .failure(message)
            case .success(let pane):
                guard pane.state == .connected, let connection = pane.connection else {
                    return .failure("tab is not connected")
                }
                connection.write(Data(text.utf8))
                return .success()
            }

        case "read-screen":
            switch resolvePane(request.args["tab"]) {
            case .failure(let message): return .failure(message)
            case .success(let pane):
                var text = pane.dumpScrollback()
                if let lines = request.args["lines"].flatMap(Int.init), lines > 0 {
                    text = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .suffix(lines).joined(separator: "\n")
                }
                return .success(json: jsonString(["text": text]))
            }

        case "set-status":
            guard let text = request.args["text"] else {
                return .failure("set-status needs text")
            }
            switch resolvePane(request.args["tab"]) {
            case .failure(let message): return .failure(message)
            case .success(let pane):
                pane.postStatus(text)
                return .success()
            }

        case "agent-event":
            // An agent's own hook reporting real semantics ("finished", "needs
            // approval") — richer than the bell guess. Targets the tab named in
            // MACMOBA_TAB (local terminals export it); without one, it is an
            // app-level notification.
            let source = request.args["source"] ?? "agent"
            let event = request.args["event"] ?? "event"
            let body = request.args["body"] ?? ""
            let summary = body.isEmpty ? "\(source): \(event)" : "\(source): \(body)"

            var targetTab: SessionTab?
            if let spec = request.args["tab"], !spec.isEmpty {
                if let uuid = UUID(uuidString: spec) {
                    // MACMOBA_TAB carries the LOCAL terminal's id.
                    targetTab = allTabs.first {
                        $0.localTerminal?.id == uuid || $0.id == uuid
                            || $0.panes.contains { $0.id == uuid }
                    }
                } else if let index = Int(spec), allTabs.indices.contains(index) {
                    targetTab = allTabs[index]
                } else {
                    targetTab = allTabs.first {
                        $0.title.localizedCaseInsensitiveContains(spec)
                    }
                }
            }
            if let tab = targetTab {
                tab.localTerminal?.markAttention()
                if let pane = tab.focusedPane { pane.postStatus(summary) }
            }
            if NSApp.isActive {
                notify(summary)
            } else {
                AttentionNotifier.post(title: targetTab?.title ?? "Agent",
                                       body: summary,
                                       paneID: targetTab?.id ?? UUID())
            }
            return .success()

        case "notify":
            guard let title = request.args["title"], !title.isEmpty else {
                return .failure("notify needs --title")
            }
            let body = request.args["body"] ?? ""
            notify(body.isEmpty ? title : "\(title) — \(body)")
            return .success()

        default:
            return .failure("unknown command “\(request.cmd)” "
                + "(ping, list-tabs, open, open-url, send, read-screen, set-status, notify)")
        }
    }

    // MARK: - helpers

    /// A tab argument is an index from `list-tabs` or a (case-insensitive)
    /// title fragment; the tab's focused pane is the addressee.
    private func resolvePane(_ spec: String?) -> Result<TerminalTab, String> {
        let tabs = allTabs
        guard !tabs.isEmpty else { return .failure("no open tabs") }
        let tab: SessionTab?
        if let spec, !spec.isEmpty {
            if let index = Int(spec) {
                tab = tabs.indices.contains(index) ? tabs[index] : nil
            } else {
                tab = tabs.first { $0.title.localizedCaseInsensitiveContains(spec) }
            }
        } else {
            tab = windows.first?.selectedTab ?? tabs.first
        }
        guard let tab else { return .failure("no tab matches “\(spec ?? "")”") }
        guard !tab.isSinglePane, let pane = tab.focusedPane else {
            return .failure("tab “\(tab.title)” has no terminal pane")
        }
        return .success(pane)
    }

    private func stateName(_ tab: SessionTab) -> String {
        switch tab.aggregateState {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .closed: return "closed"
        }
    }

    private func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Swift's Result with a plain error string, for terse command plumbing.
private typealias Result<T, E> = Swift.Result<T, String>
extension String: @retroactive Error {}

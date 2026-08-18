// The inspector panel (P1-5): single-click a session to see it, double-click
// to connect — the Finder's grammar. Shows what the 680-pt editor would bury:
// where this connects, whether it is reachable right now, and the notes and
// tags you actually consult before connecting. Notes, tags and colour are
// editable in place; structural changes still go through Edit….
//
// Hand-rolled as a trailing panel rather than `.inspector` because the app
// supports macOS 13; visually it is the same 260-pt column Royal TSX uses.

import MacMobaCore
import SwiftUI

struct SessionInspectorView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState

    @State private var editingSession: SessionConfig?
    @State private var monitoringSession: SessionConfig?
    @State private var health: Reachability?
    @State private var checkingHealth = false
    // In-place edits, debounced into the vault so typing a note is not one
    // encrypt-and-write per keystroke.
    @State private var notesDraft = ""
    @State private var tagsDraft = ""
    @State private var saveDebounce: DispatchWorkItem?

    private var session: SessionConfig? {
        guard let id = window.selectedSessionID else { return nil }
        return app.data.sessions.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(session)
                        Divider()
                        target(session)
                        healthCard(session)
                        Divider()
                        organizeFields(session)
                        Divider()
                        quickActions(session)
                    }
                    .padding(14)
                }
            } else if let group = window.selectedGroup {
                GroupDashboardView(group: group)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Select a session to inspect it")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 260)
        .background(.background)
        .onChange(of: window.selectedSessionID) { _ in
            syncDrafts()
            health = nil
        }
        .onAppear(perform: syncDrafts)
        .sheet(item: $editingSession) { s in
            SessionEditView(original: s) { app.upsertSession($0) }
        }
        .sheet(item: $monitoringSession) { s in
            ServerMonitorView(session: s).environmentObject(app)
        }
    }

    // MARK: - sections

    private func header(_ s: SessionConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.sessionKind.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.headline).lineLimit(2)
                Text(s.sessionKind.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
    }

    private func target(_ s: SessionConfig) -> some View {
        let text: String
        if s.sessionKind == .serial {
            text = "\(s.host) @ \(s.serialSettings.baud) \(s.serialSettings.formatString)"
        } else if s.sessionKind.isWeb {
            text = s.webURL ?? s.host
        } else if s.username.isEmpty {
            text = "\(s.host):\(s.port)"
        } else {
            text = "\(s.username)@\(s.host):\(s.port)"
        }
        return HStack {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy")
        }
    }

    @ViewBuilder private func healthCard(_ s: SessionConfig) -> some View {
        if s.reachabilityTarget != nil {
            HStack(spacing: 8) {
                switch health {
                case .up(let ms):
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Reachable · \(ms) ms").font(.callout)
                case .down(let reason):
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(reason).font(.callout).lineLimit(2)
                case nil:
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                    Text("Not checked").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(checkingHealth ? "…" : "Check") { checkHealth(s) }
                    .controlSize(.small)
                    .disabled(checkingHealth)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func organizeFields(_ s: SessionConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Colour: same fixed swatch palette as the editor.
            HStack(spacing: 6) {
                ForEach(SessionColor.allCases) { swatch in
                    Button {
                        var updated = s
                        updated.color = swatch == .none ? nil : swatch.rawValue
                        app.upsertSession(updated)
                    } label: {
                        Circle()
                            .fill(swatch.swiftUIColor ?? Color.secondary.opacity(0.25))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(
                                s.colorTag == swatch ? Color.primary : .clear, lineWidth: 1.5)
                                .padding(-2))
                    }
                    .buttonStyle(.plain)
                    .help(swatch.displayName)
                }
                Spacer()
            }
            TextField("Tags", text: $tagsDraft, prompt: Text("tags, comma-separated"))
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onChange(of: tagsDraft) { _ in scheduleSave(s) }
            VStack(alignment: .leading, spacing: 3) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notesDraft)
                    .frame(minHeight: 60, maxHeight: 120)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: notesDraft) { _ in scheduleSave(s) }
            }
        }
    }

    private func quickActions(_ s: SessionConfig) -> some View {
        VStack(spacing: 6) {
            Button {
                window.openTab(for: s)
            } label: {
                Label("Connect", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            HStack(spacing: 6) {
                Button("Edit…") { editingSession = s }
                    .frame(maxWidth: .infinity)
                if s.sessionKind.authenticatesOverSSH {
                    Button("Monitor…") { monitoringSession = s }
                        .frame(maxWidth: .infinity)
                }
                Button("Duplicate") {
                    let copy = SessionDuplicate.copy(
                        of: s, existingNames: app.data.sessions.map(\.name))
                    app.upsertSession(copy)
                    window.selectedSessionID = copy.id
                    editingSession = copy
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
    }

    // MARK: - plumbing

    private func syncDrafts() {
        saveDebounce?.cancel()
        notesDraft = session?.notes ?? ""
        tagsDraft = SessionSearch.tagString(session?.tags)
    }

    /// Write tags/notes back 0.8 s after typing stops — live enough to feel in
    /// place, without an encrypt-and-write per keystroke.
    private func scheduleSave(_ s: SessionConfig) {
        saveDebounce?.cancel()
        let notes = notesDraft, tags = tagsDraft
        let work = DispatchWorkItem {
            guard var current = app.data.sessions.first(where: { $0.id == s.id }) else { return }
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            current.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            let cleanTags = SessionSearch.normalizedTags(tags)
            current.tags = cleanTags.isEmpty ? nil : cleanTags
            app.upsertSession(current)
        }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Manual check. A direct host gets a plain TCP probe; one behind a jump
    /// host is opened THROUGH the chain, because its address only means
    /// something on the bastion's network. That costs an SSH login, which is
    /// why the background sweep skips these and only this button does it.
    private func checkHealth(_ s: SessionConfig) {
        guard let target = s.reachabilityTarget else { return }
        checkingHealth = true
        if s.isDirectlyProbeable {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = ReachabilityProbe.check(host: target.host, port: target.port, timeout: 2)
                DispatchQueue.main.async {
                    health = result
                    checkingHealth = false
                }
            }
            return
        }
        Task {
            let started = Date()
            do {
                let chain = try await SecretResolver.resolve(sessions: app.jumpChain(for: s))
                let resolved = try await SecretResolver.resolve(session: s)
                // Opening the forward IS the proof: the bastion accepted us and
                // the target accepted the channel.
                let route = try await RemoteDesktopRoute.open(
                    target: resolved, via: chain.last, viaHops: chain.dropLast().map { $0 },
                    hostKeys: app.hostKeyVerification)
                route.close()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                await MainActor.run {
                    health = .up(latencyMs: ms)
                    checkingHealth = false
                }
            } catch {
                await MainActor.run {
                    health = .down(reason: "via jump host: \(error.localizedDescription)")
                    checkingHealth = false
                }
            }
        }
    }
}

// Sidebar: saved sessions (double-click to connect) and tunnels (toggle to start).
// Sessions can be dragged onto group folders to move them.

import MacMobaCore
import SwiftUI
import UniformTypeIdentifiers

/// Session drags carry a plain string ("macmoba-session:<id>"). A standard
/// pasteboard type is used deliberately: custom UTTypes must be declared in
/// Info.plist or the pasteboard silently drops them, which is why earlier
/// attempts never reached the drop target. Drops validate the prefix and the
/// id, so stray text drags are ignored.
enum SessionDragPayload {
    static let prefix = "macmoba-session:"

    static func encode(_ session: SessionConfig) -> String {
        prefix + session.id
    }

    static func decodeID(_ text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count))
    }
}

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var window: WindowState
    @Environment(\.openWindow) private var openWindow
    @State private var editingSession: SessionConfig?
    @State private var editingTunnel: TunnelConfig?
    @State private var showNewSession = false
    @State private var showNewTunnel = false
    @State private var newFromTemplate: SessionConfig?
    @State private var showImporter = false
    @State private var monitoringSession: SessionConfig?
    @State private var collapsedGroups: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? [])
    @State private var newGroupSession: SessionConfig?
    @State private var newGroupName = ""
    /// Parent path for "New Subfolder…" — "" means top level, nil means the
    /// sheet is closed. (A folder can be created before it holds anything.)
    @State private var newFolderParent: String?
    @State private var newFolderName = ""
    @State private var renamingGroup: String?
    @State private var renameGroupText = ""
    @State private var dropGroupTarget: String? // group name, or "" for ungroup
    @State private var searchText = ""
    /// Type-select: letters typed with the list focused jump to a connection,
    /// the way they do in Finder. See TypeSelect for the two rules.
    @State private var typeSelect = TypeSelectBuffer()

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Sessions in a group that match the current search (all of them when the
    /// box is empty).
    private func matchingSessions(inGroup group: String?) -> [SessionConfig] {
        app.sessions(inGroup: group).filter { SessionSearch.matches($0, query: searchText) }
    }

    /// Groups that still have a visible session — an empty group is hidden while
    /// searching so the list is only what matched.
    private var visibleGroups: [String] {
        app.sessionGroups.filter { !matchingSessions(inGroup: $0).isEmpty || !isSearching }
    }

    /// Every session in the order it appears on screen — what type-select walks.
    private var typeSelectTargets: [SessionConfig] {
        displayGroupRows.flatMap { matchingSessions(inGroup: $0.path) }
            + matchingSessions(inGroup: nil)
    }

    /// The folder rows to draw, depth-first with implied parents. While
    /// searching, nothing counts as collapsed (matches must be visible) and
    /// ancestors of matching folders appear automatically.
    private var displayGroupRows: [GroupTree.Row] {
        GroupTree.displayRows(groups: visibleGroups,
                              // Empty folders exist only in this list.
                              folders: isSearching ? [] : app.data.folders,
                              collapsed: isSearching ? [] : collapsedGroups)
    }

    var body: some View {
        VStack(spacing: 0) {
        // Pinned above the list (P1-4): with a hundred sessions the search box
        // must not scroll away with them.
        if app.data.sessions.count > 4 || isSearching {
            searchField
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        List {
            Section {
                if app.data.sessions.isEmpty {
                    Text("No sessions yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else if isSearching && visibleGroups.isEmpty
                            && matchingSessions(inGroup: nil).isEmpty {
                    Text("No sessions match “\(searchText)”")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                // Groups are plain rows with a hand-rolled disclosure triangle:
                // DisclosureGroup labels don't reliably receive drops, since the
                // disclosure control owns their hit testing.
                //
                // Nested folders (the Royal TSX tree): "Production/Linux" is the
                // Linux folder inside Production. GroupTree derives the depth-first
                // rows — implied parents included — and drops anything inside a
                // collapsed ancestor, so this stays one flat ForEach.
                ForEach(displayGroupRows, id: \.path) { row in
                    groupHeaderRow(row)
                    // A search expands every group so its matches are visible.
                    if !collapsedGroups.contains(row.path) || isSearching {
                        ForEach(matchingSessions(inGroup: row.path)) { session in
                            sessionRow(session)
                                .padding(.leading, CGFloat(14 + row.depth * 14))
                        }
                    }
                }
                ForEach(matchingSessions(inGroup: nil)) { session in
                    sessionRow(session)
                }
                ungroupDropRow
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    // Click adds a plain session; the menu also offers starting
                    // from a saved template.
                    Menu {
                        Button("New Session…") { showNewSession = true }
                        Button("New Folder…") {
                            newFolderParent = ""      // "" = top level
                            newFolderName = ""
                        }
                        Button("Discover on Network…") { window.showDiscover = true }
                        Button("Import from Other Apps…") { showImporter = true }
                        if !app.data.templates.isEmpty {
                            Divider()
                            ForEach(app.data.templates) { template in
                                Button("From “\(template.name)”") {
                                    newFromTemplate = app.sessionFromTemplate(template)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    } primaryAction: {
                        showNewSession = true
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Section {
                if app.data.tunnels.isEmpty {
                    Text("No tunnels yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(app.data.tunnels) { tunnel in
                    TunnelRow(tunnel: tunnel)
                        .contextMenu {
                            Button("Edit…") { editingTunnel = tunnel }
                            Divider()
                            Button("Delete", role: .destructive) { app.deleteTunnel(tunnel) }
                        }
                }
            } header: {
                HStack {
                    Text("Tunnels")
                    Spacer()
                    Button { showNewTunnel = true } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .disabled(app.data.sessions.isEmpty)
                }
            }
        }
        .listStyle(.sidebar)
        // Typing letters selects the matching connection. Only plain characters
        // are taken: modifiers stay with the menus, and arrows/space keep their
        // list behaviour, so this never eats a key the list needs.
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  let character = press.characters.first,
                  TypeSelectBuffer.isSearchable(character) else {
                return .ignored
            }
            let prefix = typeSelect.append(character,
                                           at: Date().timeIntervalSinceReferenceDate)
            let sessions = typeSelectTargets
            let names = sessions.map(\.name)
            let current = sessions.firstIndex { $0.id == window.selectedSessionID }
            guard let hit = TypeSelect.match(prefix: prefix, in: names, current: current) else {
                return .handled
            }
            window.selectedSessionID = sessions[hit].id
            window.selectedGroup = nil
            return .handled
        }
        // The management home for macros / credentials / templates: one quiet
        // button, not three permanent sections (P1-4).
        Divider()
        HStack {
            Button {
                openWindow(id: "library")
            } label: {
                Label("Library", systemImage: "books.vertical")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Macros, credentials and templates (⌥⌘L)")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        }
        .alert(newFolderParent?.isEmpty == false
               ? "New Subfolder in “\(newFolderParent ?? "")”" : "New Folder",
               isPresented: Binding(
            get: { newFolderParent != nil },
            set: { if !$0 { newFolderParent = nil } }
        )) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let parent = newFolderParent?.isEmpty == false ? newFolderParent : nil
                if let path = app.createFolder(under: parent, name: newFolderName) {
                    // Reveal it: an ancestor left collapsed would hide the
                    // folder the user just asked for.
                    for ancestor in GroupTree.ancestors(of: path) {
                        collapsedGroups.remove(ancestor)
                    }
                    window.selectedGroup = path
                    window.selectedSessionID = nil
                }
                newFolderParent = nil
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) {
                newFolderParent = nil
                newFolderName = ""
            }
        }
        .alert("New Group", isPresented: Binding(
            get: { newGroupSession != nil },
            set: { if !$0 { newGroupSession = nil } }
        )) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                if let session = newGroupSession, !newGroupName.isEmpty {
                    app.setGroup(newGroupName, for: session)
                }
                newGroupSession = nil
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) {
                newGroupSession = nil
                newGroupName = ""
            }
        }
        .alert("Rename Group", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("Group name", text: $renameGroupText)
            Button("Rename") {
                if let old = renamingGroup, !renameGroupText.isEmpty {
                    app.renameGroup(old, to: renameGroupText)
                }
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
        .sheet(isPresented: $showNewSession) {
            SessionEditView(original: nil) { app.upsertSession($0) }
        }
        .sheet(item: $editingSession) { session in
            SessionEditView(original: session) { app.upsertSession($0) }
        }
        .sheet(isPresented: $showNewTunnel) {
            TunnelEditView(original: nil) { app.upsertTunnel($0) }
        }
        .sheet(item: $editingTunnel) { tunnel in
            TunnelEditView(original: tunnel) { app.upsertTunnel($0) }
        }
        // Creating a session from a template opens the normal editor, pre-filled,
        // so the host and name can be finished before it is saved.
        .sheet(item: $newFromTemplate) { draft in
            SessionEditView(original: draft) { app.upsertSession($0) }
        }
        .sheet(isPresented: $window.showDiscover) {
            DiscoverView { discovered in
                // Open the editor pre-filled so a login can be added before save.
                newFromTemplate = discovered
            }
        }
        .sheet(item: $monitoringSession) { session in
            ServerMonitorView(session: session).environmentObject(app)
        }
        // Any file: the format is sniffed from content, so an extension-less
        // OpenSSH `config` is as pickable as a `.reg` or `.rdg`.
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let n = app.importSessions(from: url)
                // Failure paths already set app.lastError (which banners);
                // only success needs announcing here.
                if n > 0 {
                    app.infoMessage = "Imported \(n) session\(n == 1 ? "" : "s") "
                        + "from \(url.lastPathComponent)."
                }
            case .failure(let error):
                app.lastError = error.localizedDescription
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search name, host, tag, note…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if isSearching {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Group folder row: click to expand/collapse, drop a session on it to move.
    /// Nested folders indent by depth and show only their own segment name;
    /// the count includes everything underneath (a folder is its subtree).
    private func groupHeaderRow(_ row: GroupTree.Row) -> some View {
        let group = row.path
        let collapsed = collapsedGroups.contains(group)
        let targeted = dropGroupTarget == group
        let total = app.data.sessions.filter { GroupTree.contains(group, group: $0.group) }.count
        return HStack(spacing: 4) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: targeted ? "folder.fill" : "folder")
                .foregroundStyle(.tint)
            Text(row.name)
                .fontWeight(.medium)
            Spacer()
            Text("\(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .padding(.leading, CGFloat(row.depth) * 14)
        .background(targeted ? Color.accentColor.opacity(0.30) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            toggleGroup(group)
            // Clicking a folder also selects it, so the inspector can show the
            // group's dashboard (P2-13) — the Royal TSX folder gesture.
            window.selectedGroup = group
            window.selectedSessionID = nil
        }
        .onDrop(of: [.text], isTargeted: dropBinding(group)) { providers in
            handleSessionDrop(providers, toGroup: group)
        }
        .contextMenu {
            Button("Connect All") { window.connectGroup(group) }
            Button("New Subfolder…") {
                newFolderParent = group
                newFolderName = ""
            }
            Button("Rename Group…") {
                renameGroupText = group
                renamingGroup = group
            }
            // The default login for sessions in this group whose Login is set to
            // "Inherit from group".
            Menu("Group Credential") {
                Button {
                    app.setGroupCredential(nil, for: group)
                } label: {
                    Label("None", systemImage:
                            app.groupCredentialID(for: group) == nil ? "checkmark" : "")
                }
                if !app.data.credentials.isEmpty { Divider() }
                ForEach(app.data.credentials) { credential in
                    Button {
                        app.setGroupCredential(credential.id, for: group)
                    } label: {
                        Label(credential.name, systemImage:
                                app.groupCredentialID(for: group) == credential.id
                                ? "checkmark" : "")
                    }
                }
            }
            Divider()
            Button("Disband Group") { app.disbandGroup(group) }
        }
    }

    /// Explicit drop zone for removing a session from its group.
    @ViewBuilder
    private var ungroupDropRow: some View {
        if !app.sessionGroups.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "tray")
                    .foregroundStyle(.secondary)
                Text("Drop here to ungroup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(dropGroupTarget == "" ? Color.accentColor.opacity(0.30) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onDrop(of: [.text], isTargeted: dropBinding("")) { providers in
                handleSessionDrop(providers, toGroup: nil)
            }
        }
    }

    private func sessionRow(_ session: SessionConfig) -> some View {
        SessionRow(session: session)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(window.selectedSessionID == session.id
                        ? Color.accentColor.opacity(0.20) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onDrag {
                window.selectedSessionID = session.id
                window.selectedGroup = nil
                return NSItemProvider(object: SessionDragPayload.encode(session) as NSString)
            }
            .onTapGesture(count: 2) { window.openTab(for: session) }
            .onTapGesture(count: 1) {
                window.selectedSessionID = session.id
                window.selectedGroup = nil
            }
            .contextMenu {
                Button("Connect") { window.openTab(for: session) }
                Button("Edit…") { editingSession = session }
                if session.sessionKind.authenticatesOverSSH {
                    Button("Server Monitor…") { monitoringSession = session }
                }
                // Saved straight away and then opened for editing: the copy
                // exists whether or not the editor is confirmed, which is how
                // Duplicate behaves everywhere else on the Mac.
                Button("Duplicate") {
                    let copy = SessionDuplicate.copy(
                        of: session, existingNames: app.data.sessions.map(\.name))
                    app.upsertSession(copy)
                    window.selectedSessionID = copy.id
                    editingSession = copy
                }
                Menu("Move to Group") {
                    Button("None") { app.setGroup(nil, for: session) }
                    if !app.sessionGroups.isEmpty { Divider() }
                    ForEach(app.sessionGroups, id: \.self) { group in
                        Button(group) { app.setGroup(group, for: session) }
                    }
                    Divider()
                    Button("New Group…") {
                        newGroupName = ""
                        newGroupSession = session
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { app.deleteSession(session) }
            }
    }

    private func handleSessionDrop(_ providers: [NSItemProvider], toGroup group: String?) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String,
                  let id = SessionDragPayload.decodeID(text) else { return }
            Task { @MainActor in
                guard let session = app.data.sessions.first(where: { $0.id == id }) else { return }
                app.setGroup(group, for: session)
            }
        }
        return true
    }

    private func dropBinding(_ group: String) -> Binding<Bool> {
        Binding(
            get: { dropGroupTarget == group },
            set: { targeted in
                if targeted {
                    dropGroupTarget = group
                } else if dropGroupTarget == group {
                    dropGroupTarget = nil
                }
            }
        )
    }

    private func toggleGroup(_ group: String) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
            collapsedGroups.insert(group)
        }
        UserDefaults.standard.set(Array(collapsedGroups), forKey: "collapsedGroups")
    }

    private func expansionBinding(_ group: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(group) },
            set: { expanded in
                if expanded {
                    collapsedGroups.remove(group)
                } else {
                    collapsedGroups.insert(group)
                }
                UserDefaults.standard.set(Array(collapsedGroups), forKey: "collapsedGroups")
            }
        )
    }
}

struct SessionRow: View {
    let session: SessionConfig
    @EnvironmentObject var health: HealthMonitor

    private var icon: String { session.sessionKind.symbolName }

    /// Reachability light: green up, red down, grey unknown/not-yet-checked.
    /// Absent entirely when monitoring is off, so the row is unchanged then.
    @ViewBuilder private var healthDot: some View {
        if health.isEnabled, session.reachabilityTarget != nil,
           !session.isDirectlyProbeable {
            // Branch = how it is reached; the dot still reports whether it
            // answered the last time anyone checked through the bastion.
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Circle()
                    .fill({ () -> Color in
                        switch health.status[session.id] {
                        case .up: return .green
                        case .down: return .red
                        case nil: return .secondary.opacity(0.3)
                        }
                    }())
                    .frame(width: 6, height: 6)
            }
            .help({ () -> String in
                switch health.status[session.id] {
                case .up(let ms): return "Reachable through the jump host · \(ms) ms"
                case .down(let reason): return reason
                case nil: return "Reached through a jump host — check it from the folder dashboard"
                }
            }())
        } else if health.isEnabled, session.reachabilityTarget != nil {
            let color: Color = {
                switch health.status[session.id] {
                case .up: return .green
                case .down: return .red
                case nil: return .secondary.opacity(0.4)
                }
            }()
            let help: String = {
                switch health.status[session.id] {
                case .up(let ms): return "Reachable (\(ms) ms)"
                case .down(let reason): return "Unreachable: \(reason)"
                case nil: return "Checking…"
                }
            }()
            Circle().fill(color).frame(width: 7, height: 7).help(help)
                .accessibilityLabel(help)
        }
    }

    /// Tint per protocol, so the three kinds are distinguishable even when the
    /// glyphs are small.
    private var tint: Color {
        switch session.sessionKind {
        case .ssh: return .accentColor
        // Green: same trust properties as SSH (it bootstraps over it), and the
        // distinction worth showing is that it survives a dropped network.
        case .mosh: return .green
        // Orange, not another neutral tint: Telnet is the one protocol here
        // that sends your password in clear text, and the sidebar is where
        // people pick without thinking.
        case .telnet: return .orange
        // Cleartext like Telnet — same warning colour.
        case .rlogin: return .orange
        // Orange for the same reason as Telnet when it is plain FTP; a session
        // using TLS is not in that category, so it is not tinted as if it were.
        case .ftp: return session.sendsCredentialsInClear ? .orange : .blue
        case .web: return .indigo
        case .vnc: return .purple
        case .rdp: return .teal
        case .serial: return .brown
        }
    }

    /// SSH shows user@host:port; the others usually have no useful username,
    /// so they lead with the protocol instead.
    private var subtitle: String {
        let target = "\(session.host):\(String(session.port))"
        switch session.sessionKind {
        case .ssh, .mosh: return "\(session.username)@\(target)"
        case .rlogin:
            return session.username.isEmpty
                ? "Rlogin \(target)" : "Rlogin \(session.username)@\(target)"
        case .web:
            return session.webURL ?? session.host
        case .ftp:
            let label = session.ftpSecurity == .implicitTLS ? "FTPS" : "FTP"
            return session.username.isEmpty
                ? "\(label) \(target)"
                : "\(label) \(session.username)@\(target)"
        // A serial line has a device path and a baud rate, not host:port.
        case .serial:
            return "Serial \(session.host) @ \(session.serialSettings.baud)"
        case .telnet, .vnc, .rdp:
            return "\(session.sessionKind.displayName) \(target)"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Colour tag on the far left, so a coloured session stands out in a
            // long list even before you read its name. Absent when uncoloured.
            if let dot = session.colorTag.swiftUIColor {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.name)
                    if let first = session.tags?.first {
                        tagChip(first)
                        if (session.tags?.count ?? 0) > 1 {
                            Text("+\((session.tags?.count ?? 1) - 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            healthDot
        }
        .help(session.notes?.isEmpty == false ? session.notes! : "Double-click to connect")
    }

    private func tagChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

struct TunnelRow: View {
    @EnvironmentObject var app: AppState
    let tunnel: TunnelConfig

    private var isActive: Bool { app.activeForwards[tunnel.id] != nil }

    var body: some View {
        HStack {
            Image(systemName: tunnel.type == "remote" ? "arrow.uturn.down"
                            : tunnel.type == "dynamic" ? "globe" : "arrow.triangle.branch")
                .foregroundStyle(isActive ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.name)
                Text(tunnel.type == "dynamic"
                     ? "SOCKS5 127.0.0.1:\(String(tunnel.bindPort)) via \(app.sessionName(for: tunnel.sessionId))"
                     : tunnel.type == "remote"
                     ? "server:\(String(tunnel.bindPort)) → \(tunnel.targetHost):\(String(tunnel.targetPort)) (local) via \(app.sessionName(for: tunnel.sessionId))"
                     : "localhost:\(String(tunnel.bindPort)) → \(tunnel.targetHost):\(String(tunnel.targetPort)) via \(app.sessionName(for: tunnel.sessionId))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isActive },
                set: { _ in app.toggleTunnel(tunnel) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
    }
}

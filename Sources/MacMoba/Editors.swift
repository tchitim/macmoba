// Sheets for creating/editing sessions and tunnels.

import MacMobaCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionEditView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let original: SessionConfig?
    /// When true the sheet is editing a template: the host may be left blank
    /// (it is filled in when a session is created from the template), and fields
    /// can carry `%host%`-style tokens.
    var isTemplate: Bool = false
    let onSave: (SessionConfig) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = 22
    @State private var username = ""
    @State private var authType = "password"
    @State private var password = ""
    @State private var keyPath = ""
    @State private var passphrase = ""
    @State private var group = ""
    @State private var proxyJump = ""
    @State private var kind: SessionKind = .ssh
    @State private var domain = ""
    @State private var rdpSecurity: RDPSecurity = .negotiate
    @State private var sharedFolders: [String] = []
    @State private var displayMode: RDPDisplayMode = .fitWindow
    @State private var fixedWidth = 1920
    @State private var fixedHeight = 1080
    @State private var useAllDisplays = false
    @State private var ftpSecurity: FTPSecurity = .plain
    @State private var webURL = ""
    /// "custom" = this session's own inline fields; a credential id = that
    /// shared login; "inherit" = the group's default. See CredentialResolver.
    @State private var credentialRef = "custom"
    @State private var colorTag: SessionColor = .none
    @State private var tagsText = ""
    @State private var notes = ""
    @State private var onConnectCommands = ""
    @State private var expectText = ""
    @State private var x11Forwarding = false
    @State private var fallbackHostsText = ""
    @State private var serialBaud = 9600
    @State private var serialFormat = "8N1"

    /// The editor's categories (P0-1). One tall stacked form had grown past
    /// 1100 pt for SSH — taller than a 13" screen — so the sheet is now a fixed
    /// size with a category rail on the left. Which categories exist follows
    /// the protocol; a session's non-default categories are dotted in the rail.
    private enum EditorCategory: String, CaseIterable, Identifiable {
        case general, login, connection, automation, display, organize
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .login: return "Login"
            case .connection: return "Connection"
            case .automation: return "Automation"
            case .display: return "Display"
            case .organize: return "Organize"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .login: return "person.badge.key"
            case .connection: return "point.3.connected.trianglepath.dotted"
            case .automation: return "wand.and.stars"
            case .display: return "display"
            case .organize: return "tag"
            }
        }
    }

    @State private var category: EditorCategory = .general
    @State private var confirmDiscard = false
    /// Snapshot of every field at load time; Cancel compares against it so only
    /// a genuinely edited sheet asks before discarding.
    @State private var initialSignature = ""

    private var availableCategories: [EditorCategory] {
        var cats: [EditorCategory] = [.general]
        // Web pages authenticate themselves; a serial line has no login.
        if kind != .web && kind != .serial { cats.append(.login) }
        // A serial line is a local cable — nothing to tunnel or fail over.
        if kind != .serial { cats.append(.connection) }
        if kind == .ssh || kind == .mosh || kind == .telnet || kind == .rlogin {
            cats.append(.automation)
        }
        if kind == .rdp || kind == .serial { cats.append(.display) }
        cats.append(.organize)
        return cats
    }

    /// Whether a category holds anything beyond defaults — the rail's dot.
    private func hasCustomization(_ c: EditorCategory) -> Bool {
        switch c {
        case .general:
            return false   // identity, not customization
        case .login:
            return credentialRef != "custom" || !password.isEmpty
                || authType == "keyfile" || !domain.isEmpty
                || (kind == .ftp && ftpSecurity != .plain)
        case .connection:
            return !proxyJump.isEmpty
                || !fallbackHostsText.trimmingCharacters(in: .whitespaces).isEmpty
                || (kind == .rdp && rdpSecurity != .negotiate)
        case .automation:
            return !onConnectCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !expectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || x11Forwarding
        case .display:
            if kind == .serial { return serialBaud != 9600 || serialFormat != "8N1" }
            return displayMode != .fitWindow || useAllDisplays || !sharedFolders.isEmpty
        case .organize:
            return colorTag != .none
                || !tagsText.trimmingCharacters(in: .whitespaces).isEmpty
                || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Every editable field, flattened. Compared at Cancel time against the
    /// load-time snapshot to decide whether "discard changes?" is warranted.
    private var fieldSignature: String {
        [name, host, String(port), username, authType, password, keyPath,
         passphrase, group, proxyJump, kind.rawValue, domain,
         rdpSecurity.rawValue, sharedFolders.joined(separator: "|"),
         displayMode.rawValue, String(fixedWidth), String(fixedHeight),
         String(useAllDisplays), ftpSecurity.rawValue, webURL, credentialRef,
         colorTag.rawValue, tagsText, notes, onConnectCommands, expectText,
         String(x11Forwarding), fallbackHostsText, String(serialBaud),
         serialFormat]
            .joined(separator: "\u{1F}")
    }

    /// SSH sessions this one can be reached through — a VNC/RDP session
    /// tunnels its TCP port over one, an SSH session jumps through it.
    private var sshSessions: [SessionConfig] {
        app.data.sessions.filter { $0.sessionKind == .ssh && $0.id != original?.id }
    }

    /// True when the login comes from a shared credential (named or inherited)
    /// rather than the fields on this session, so the inline auth fields are
    /// hidden — the credential supplies them.
    private var usesSharedLogin: Bool {
        credentialRef != "custom" && !credentialRef.isEmpty
    }

    /// Whether a login even applies. Web pages authenticate themselves, a
    /// Telnet login happens at the remote's own prompt, and a serial line has
    /// no login at all.
    private var kindHasLogin: Bool {
        kind != .web && kind != .telnet && kind != .serial
    }

    /// A one-line description of the shared login in use, for the note shown in
    /// place of the hidden fields.
    private var sharedLoginSummary: String? {
        guard usesSharedLogin else { return nil }
        if credentialRef == CredentialResolver.inherit {
            if group.isEmpty { return "Inherit from group — but no group is set" }
            guard let id = app.groupCredentialID(for: group),
                  let c = app.data.credentials.first(where: { $0.id == id }) else {
                return "Inherit from group \"\(group)\" — no default set, using inline fields"
            }
            return "Inherited from group \"\(group)\": \(c.name) (\(c.username))"
        }
        guard let c = app.data.credentials.first(where: { $0.id == credentialRef }) else {
            return "Credential no longer exists — using inline fields"
        }
        return "\(c.name) (\(c.username.isEmpty ? "no username" : c.username))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                categoryList
                Divider()
                Form {
                    switch category {
                    case .general: generalSections
                    case .login: loginSections
                    case .connection: connectionSections
                    case .automation: automationSections
                    case .display: displaySections
                    case .organize: organizeSections
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            buttonBar
        }
        // Fixed size (P0-1): a category whose content outgrows the sheet scrolls
        // within its own Form — the sheet never grows. This replaces the
        // per-protocol height arithmetic that had pushed the SSH editor past
        // 1100 pt, taller than a 13" screen.
        .frame(width: 680, height: 540)
        .onAppear {
            load()
            initialSignature = fieldSignature
        }
        .onChange(of: kind) { _ in
            // A protocol switch can remove the category being shown (e.g. RDP →
            // SSH while on Display); fall back rather than showing a blank form.
            if !availableCategories.contains(category) { category = .general }
        }
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This session has unsaved edits.")
        }
    }

    /// The category rail. A dot marks a category holding non-default values, so
    /// what a session customizes is visible without visiting every tab.
    private var categoryList: some View {
        List(selection: Binding<EditorCategory?>(
            get: { category },
            set: { if let c = $0 { category = c } })) {
            ForEach(availableCategories) { c in
                HStack {
                    Label(c.title, systemImage: c.symbol)
                    Spacer()
                    if hasCustomization(c) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            .accessibilityLabel("has custom settings")
                    }
                }
                .tag(c)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 170)
    }

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Cancel") { attemptCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            // ⌘S saves too — document-editing muscle memory. Hidden because the
            // visible Save button already carries Return.
            Button("") { if canSave { save() } }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0)
                .accessibilityHidden(true)
        }
        .padding(12)
    }

    // A web session has a URL where the others have a host. A shared login
    // supplies the username, so it need not be typed here. A template needs
    // only a name — its host and login are filled when a session is created
    // from it.
    private var canSave: Bool {
        !(name.isEmpty
          || (!isTemplate
              && ((kind == .web ? webURL.isEmpty : host.isEmpty)
                  || (kind.authenticatesOverSSH && username.isEmpty
                      && !usesSharedLogin))))
    }

    private func attemptCancel() {
        if fieldSignature != initialSignature {
            confirmDiscard = true
        } else {
            dismiss()
        }
    }

    // MARK: - General

    @ViewBuilder private var generalSections: some View {
        Section("Session") {
            // A menu, not segments: nine protocols never fit a segmented row.
            Picker("Protocol", selection: $kind) {
                ForEach(SessionKind.allCases) { k in
                    Label(k.displayName, systemImage: k.symbolName).tag(k)
                }
            }
            .onChange(of: kind) { newKind in
                // Follow the default port only while it still matches some
                // protocol's default — never clobber a typed one.
                if SessionKind.allCases.contains(where: { $0.defaultPort == port }) {
                    port = newKind.defaultPort
                }
            }
            TextField("Name", text: $name, prompt: Text("prod web server"))
            if kind == .web {
                // A page, not a host and port: the URL carries both, and the
                // "via" session in Connection carries the traffic.
                TextField("URL", text: $webURL,
                          prompt: Text("http://internal.corp:8080/status"))
            } else if kind == .serial {
                serialDeviceField
            } else {
                TextField("Host", text: $host, prompt: Text("example.com"))
                TextField("Port", value: $port, format: .number.grouping(.never))
            }
            HStack {
                TextField("Group", text: $group, prompt: Text("(none — nest with /: Production/Linux)"))
                if !app.sessionGroups.isEmpty {
                    Menu {
                        ForEach(app.sessionGroups, id: \.self) { g in
                            Button(g) { group = g }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }
        }
    }

    // MARK: - Login

    @ViewBuilder private var loginSections: some View {
        if kind == .telnet || kind == .rlogin || (kind == .ftp && ftpSecurity == .plain) {
            Section {
                Label {
                    Text(kind == .ftp
                         ? "Plain FTP sends everything in clear text, including "
                           + "your password. Anyone on the network path can read "
                           + "it. Prefer SFTP (open an SSH session and use its "
                           + "file browser), or switch Encryption to implicit TLS "
                           + "if the server offers it."
                         : "\(kind.displayName) sends everything in clear text, "
                         + "including your login. Anyone on the network path can "
                         + "read it. Prefer SSH; if you must use it, send it "
                         + "through an SSH session under Connection.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
        Section("Login") {
            // A shared login: pick a credential once, reuse it here and on
            // every other session. "Custom" keeps the inline fields.
            if kindHasLogin {
                Picker("Login", selection: $credentialRef) {
                    Text("Custom (this session)").tag("custom")
                    if !group.isEmpty {
                        Text("Inherit from group").tag(CredentialResolver.inherit)
                    }
                    if !app.data.credentials.isEmpty {
                        Divider()
                        ForEach(app.data.credentials) { c in
                            Text(c.name).tag(c.id)
                        }
                    }
                }
                if let summary = sharedLoginSummary {
                    Label(summary, systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Classic VNC has no username — only Apple Remote Desktop and
            // UltraVNC ask for one — so it is labelled as optional rather than
            // presented as a required field.
            if usesSharedLogin {
                // Username comes from the shared credential; the note above
                // says which one.
                EmptyView()
            } else if kind.usesUsername {
                TextField("Username", text: $username)
            } else if kind == .telnet {
                TextField("Username", text: $username,
                          prompt: Text("(not sent — log in at the remote's prompt)"))
            } else {
                TextField("Username", text: $username,
                          prompt: Text("(only for Apple Remote Desktop / UltraVNC)"))
            }
            // Telnet has no password at all (you log in at the remote's
            // prompt), and SSH/Mosh get the full Authentication section below.
            if (kind == .vnc || kind == .rdp || kind == .ftp) && !usesSharedLogin {
                RevealableSecretField(label: "Password", text: $password)
            }
            if kind == .ftp {
                Picker("Encryption", selection: $ftpSecurity) {
                    ForEach(FTPSecurity.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: ftpSecurity) { mode in
                    // Same rule as the protocol picker: follow the default only
                    // while the port still is one.
                    if FTPSecurity.allCases.contains(where: { $0.defaultPort == port })
                        || port == SessionKind.ftp.defaultPort {
                        port = mode.defaultPort
                    }
                }
            }
            if kind == .rdp {
                TextField("Domain", text: $domain,
                          prompt: Text("(none — or use DOMAIN\\user above)"))
            }
        }
        if kind.authenticatesOverSSH && !usesSharedLogin {
            Section("Authentication") {
                Picker("Method", selection: $authType) {
                    Text("Password").tag("password")
                    Text("Private key file").tag("keyfile")
                }
                .pickerStyle(.segmented)
                if authType == "password" {
                    RevealableSecretField(label: "Password", text: $password)
                    secretHint
                } else {
                    HStack {
                        TextField("Key path", text: $keyPath,
                                  prompt: Text("~/.ssh/id_ed25519"))
                        Button("Choose…") { chooseKeyFile() }
                    }
                    RevealableSecretField(label: "Passphrase (if encrypted)", text: $passphrase)
                }
            }
        }
    }

    // MARK: - Connection

    @ViewBuilder private var connectionSections: some View {
        Section("Connection") {
            Picker(kind == .web ? "Tunnel through"
                   : (kind.usesJumpHost ? "Via jump host" : "Via SSH session"),
                   selection: $proxyJump) {
                Text(kind.usesJumpHost ? "Direct (no jump host)"
                                       : "Direct (no tunnel)").tag("")
                ForEach(sshSessions) { s in
                    Text(s.name).tag(s.id)
                }
            }
            if kind != .web && kind.usesJumpHost {
                Text("A jump host may itself have a jump host — the whole "
                     + "chain is opened in order (ssh -J b,a).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if kind != .web {
                TextField("Fallback hosts", text: $fallbackHostsText,
                          prompt: Text("standby.example.com, 10.0.0.9:2222"))
                Text("Tried in order if the host above is unreachable "
                     + "(gateway failover). Each “host” or “host:port”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if kind == .mosh {
                // Mosh is not port-forwarded, so the jump host applies to the
                // SSH bootstrap only. Saying otherwise would promise privacy
                // the UDP session does not have.
                Text("The jump host carries the SSH login that starts mosh-server. "
                     + "The session itself is UDP straight to the host above, so it "
                     + "must be reachable from this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if kind != .ssh {
                Text("With an SSH session chosen, MacMoba forwards \(kind.displayName) "
                     + "over it — so the host and port above are resolved on that "
                     + "machine. That reaches a server bound to its localhost, or one "
                     + "behind a bastion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if kind == .rdp {
            Section("Security") {
                Picker("Security", selection: $rdpSecurity) {
                    ForEach(RDPSecurity.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(rdpSecurity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Automation

    @ViewBuilder private var automationSections: some View {
        Section("On connect") {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $onConnectCommands)
                    .frame(minHeight: 54)
                    .font(.system(.callout, design: .monospaced))
                Text("Typed into the shell once connected, one command "
                     + "per line. Runs again on every reconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section("Expect / Send") {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $expectText)
                    .frame(minHeight: 54)
                    .font(.system(.callout, design: .monospaced))
                Text("Wait for a prompt, then type. One rule per line: "
                     + "`expect => send`. Use `\\n` for Enter and wrap the "
                     + "expect in slashes for a regex "
                     + "(`/[Pp]assword:/ => secret\\n`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if kind == .ssh || kind == .mosh {
            Section("X11") {
                Toggle("Forward X11 (remote GUI apps)", isOn: $x11Forwarding)
                Text("Tunnels your Mac's X server so remote GUI apps open here. "
                     + "Needs XQuartz running with TCP listening enabled "
                     + "(`defaults write org.xquartz.X11 nolisten_tcp -bool false`, "
                     + "then restart XQuartz).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Display

    @ViewBuilder private var displaySections: some View {
        if kind == .rdp {
            Section("Display") {
                Picker("Size", selection: $displayMode) {
                    ForEach(RDPDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if displayMode == .fixed {
                    // One labelled row rather than two inline-labelled fields:
                    // at this column width "Height" wraps onto two lines and
                    // reads as broken.
                    LabeledContent("Resolution") {
                        HStack(spacing: 6) {
                            TextField("", value: $fixedWidth, format: .number.grouping(.never))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                            Text("×").foregroundStyle(.secondary)
                            TextField("", value: $fixedHeight, format: .number.grouping(.never))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                        }
                    }
                }
                Text(displayMode == .fixed
                     ? displayMode.detail + " Measured in pixels."
                     : displayMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if displayMode == .fitWindow {
                    Toggle("Use all displays", isOn: $useAllDisplays)
                    Text("In full screen (⌃⇧⌘F), the session covers every "
                         + "screen and Windows treats them as separate "
                         + "monitors. Windowed, it stays in its tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Folders") {
                ForEach(sharedFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.tint)
                        Text((folder as NSString).lastPathComponent)
                        Text(folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button {
                            sharedFolders.removeAll { $0 == folder }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("Share Folder…") { chooseSharedFolder() }
                    Spacer()
                }
                Text("Shared folders appear inside the session as drives, "
                     + "so you can copy files without a network share.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if kind == .serial {
            Section("Serial Line") {
                Picker("Baud", selection: $serialBaud) {
                    ForEach(SerialSettings.commonBauds, id: \.self) { Text("\($0)").tag($0) }
                }
                TextField("Format", text: $serialFormat, prompt: Text("8N1"))
            }
        }
    }

    // MARK: - Organize

    @ViewBuilder private var organizeSections: some View {
        Section("Organize") {
            // A row of swatches, not a colour well: the palette is fixed, so
            // the sidebar stays legible on any theme.
            HStack(spacing: 8) {
                Text("Color")
                Spacer()
                ForEach(SessionColor.allCases) { swatch in
                    swatchButton(swatch)
                }
            }
            TextField("Tags", text: $tagsText,
                      prompt: Text("comma-separated: prod, eu-west, db"))
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .frame(minHeight: 54)
                    .font(.callout)
            }
        }
    }

    private func load() {
        guard let s = original else { return }
        name = s.name
        host = s.host
        port = s.port
        username = s.username
        authType = s.authType == "keyfile" ? "keyfile" : "password"
        password = s.password ?? ""
        keyPath = s.keyPath ?? ""
        passphrase = s.passphrase ?? ""
        group = s.group ?? ""
        proxyJump = s.proxyJump ?? ""
        kind = s.sessionKind
        domain = s.domain ?? ""
        rdpSecurity = RDPSecurity(rawValue: s.rdpSecurity ?? "") ?? .negotiate
        sharedFolders = s.sharedFolders ?? []
        displayMode = s.displayMode
        useAllDisplays = s.rdpUseAllDisplays ?? false
        ftpSecurity = s.ftpSecurity
        webURL = s.webURL ?? ""
        // Normalise nil/"" to "custom" so the picker has a concrete selection.
        credentialRef = (s.credentialRef?.isEmpty == false) ? s.credentialRef! : "custom"
        colorTag = s.colorTag
        tagsText = SessionSearch.tagString(s.tags)
        notes = s.notes ?? ""
        onConnectCommands = s.onConnectCommands ?? ""
        expectText = ExpectStep.formatLines(s.expectSequence ?? [])
        x11Forwarding = s.x11Forwarding ?? false
        fallbackHostsText = (s.fallbackHosts ?? []).joined(separator: ", ")
        serialBaud = s.serialBaud ?? 9600
        serialFormat = s.serialFormat ?? "8N1"
        // Keep the defaults visible when the session has never been fixed, so
        // switching to "Fixed size" starts from something sensible.
        fixedWidth = s.rdpWidth ?? fixedWidth
        fixedHeight = s.rdpHeight ?? fixedHeight
    }

    private var secretHint: some View { SecretFieldHint() }

    /// The device path for a serial session (baud and format live under
    /// Display). The picker lists the ports present now; the field stays
    /// editable for one that is unplugged.
    @ViewBuilder
    private var serialDeviceField: some View {
        HStack {
            TextField("Device", text: $host, prompt: Text("/dev/cu.usbserial-XXXX"))
            let ports = SerialPort.available()
            if !ports.isEmpty {
                Menu {
                    ForEach(ports, id: \.self) { port in
                        Button((port as NSString).lastPathComponent) { host = port }
                    }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
            }
        }
    }

    /// One palette swatch — a filled dot, ringed when selected. `.none` shows a
    /// hollow ring so "no colour" is still a clear choice.
    @ViewBuilder
    private func swatchButton(_ swatch: SessionColor) -> some View {
        let selected = colorTag == swatch
        Button {
            colorTag = swatch
        } label: {
            Circle()
                .fill(swatch.swiftUIColor ?? Color.secondary.opacity(0.25))
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(swatch == .none ? Color.secondary : .clear,
                                         lineWidth: 1))
                .overlay(Circle().stroke(Color.primary,
                                         lineWidth: selected ? 2 : 0)
                                 .padding(-2))
        }
        .buttonStyle(.plain)
        .help(swatch.displayName)
        .accessibilityLabel("Color: \(swatch.displayName)")
    }

    private func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !sharedFolders.contains(url.path) {
            sharedFolders.append(url.path)
        }
    }

    private func save() {
        var config = SessionConfig(
            id: original?.id ?? UUID().uuidString,
            name: name,
            host: host,
            port: port,
            username: kind.usesUsername || !username.isEmpty ? username : "",
            authType: authType,
            password: (kind != .ssh || authType == "password") && !password.isEmpty
                ? password : nil,
            keyPath: authType == "keyfile" && !keyPath.isEmpty ? keyPath : nil,
            keyData: nil,
            passphrase: authType == "keyfile" && !passphrase.isEmpty ? passphrase : nil,
            group: group.isEmpty ? nil : group,
            proxyJump: proxyJump.isEmpty ? nil : proxyJump,
            kind: kind == .ssh ? nil : kind.rawValue,
            domain: kind == .rdp && !domain.isEmpty ? domain : nil,
            rdpSecurity: kind == .rdp && rdpSecurity != .negotiate ? rdpSecurity.rawValue : nil,
            sharedFolders: kind == .rdp && !sharedFolders.isEmpty ? sharedFolders : nil,
            // Written only when they differ from the default, so a vault stays
            // readable by anything that predates these fields.
            rdpDisplayMode: kind == .rdp && displayMode != .fitWindow
                ? displayMode.rawValue : nil,
            rdpWidth: kind == .rdp && displayMode == .fixed ? fixedWidth : nil,
            rdpHeight: kind == .rdp && displayMode == .fixed ? fixedHeight : nil,
            ftpTLS: kind == .ftp && ftpSecurity != .plain ? ftpSecurity.rawValue : nil,
            webURL: kind == .web && !webURL.isEmpty ? webURL : nil,
            rdpUseAllDisplays: kind == .rdp && useAllDisplays && displayMode == .fitWindow
                ? true : nil
        )
        // Only stored when a shared login is actually chosen, so a plain
        // session's JSON stays exactly as before.
        config.credentialRef = (kindHasLogin && credentialRef != "custom") ? credentialRef : nil
        // Organisational metadata — written only when set, so a plain session's
        // JSON is unchanged.
        config.color = colorTag == .none ? nil : colorTag.rawValue
        let cleanTags = SessionSearch.normalizedTags(tagsText)
        config.tags = cleanTags.isEmpty ? nil : cleanTags
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        config.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        let isTerminal = kind == .ssh || kind == .mosh || kind == .telnet || kind == .rlogin
        let trimmedScript = onConnectCommands.trimmingCharacters(in: .whitespacesAndNewlines)
        config.onConnectCommands = (isTerminal && !trimmedScript.isEmpty)
            ? onConnectCommands : nil
        let expectSteps = isTerminal ? ExpectStep.parseLines(expectText) : []
        config.expectSequence = expectSteps.isEmpty ? nil : expectSteps
        let sshLike = kind == .ssh || kind == .mosh
        config.x11Forwarding = (sshLike && x11Forwarding) ? true : nil
        // Comma-separated, trimmed, empties dropped — reuse the tag splitter.
        let fallbacks = SessionSearch.normalizedTags(fallbackHostsText)
        config.fallbackHosts = (kind != .web && !fallbacks.isEmpty) ? fallbacks : nil
        // Serial settings, written only for a serial session.
        config.serialBaud = kind == .serial ? serialBaud : nil
        config.serialFormat = kind == .serial && serialFormat != "8N1" ? serialFormat : nil
        onSave(config)
        dismiss()
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path
        }
    }
}

/// A password field with an eye: dots by default, plain text while revealed.
/// Besides checking for typos, revealing is how you confirm whether a field
/// holds a real password or an `op://…` reference. The vault is already
/// unlocked when any editor is open, so no extra prompt gates the reveal.
struct RevealableSecretField: View {
    let label: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            if revealed {
                TextField(label, text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            } else {
                SecureField(label, text: $text)
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(revealed ? "Hide" : "Show")
            .accessibilityLabel(revealed ? "Hide \(label)" : "Show \(label)")
        }
    }
}

/// Tells the user a password field also accepts a manager reference.
struct SecretFieldHint: View {
    var body: some View {
        Text("Or a password-manager reference: “op://Vault/item/password” "
             + "(1Password), or “cmd:…” to run a command (Keychain, pass, "
             + "keepassxc-cli…). Fetched at connect, never stored.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A shared login: name it once, reference it from many sessions.
struct CredentialEditView: View {
    @Environment(\.dismiss) private var dismiss
    let original: CredentialConfig?
    let onSave: (CredentialConfig) -> Void

    @State private var name = ""
    @State private var username = ""
    @State private var authType = "password"
    @State private var password = ""
    @State private var keyPath = ""
    @State private var passphrase = ""
    @State private var domain = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Credential") {
                    TextField("Name", text: $name, prompt: Text("Production root"))
                    TextField("Username", text: $username, prompt: Text("root"))
                    // A domain only matters to RDP sessions; harmless elsewhere,
                    // so it lives with the credential rather than being asked for
                    // twice.
                    TextField("Windows domain", text: $domain,
                              prompt: Text("(none — RDP only, or DOMAIN\\user)"))
                }
                Section("Authentication") {
                    Picker("Method", selection: $authType) {
                        Text("Password").tag("password")
                        Text("Private key file").tag("keyfile")
                    }
                    .pickerStyle(.segmented)
                    if authType == "password" {
                        RevealableSecretField(label: "Password", text: $password)
                        SecretFieldHint()
                    } else {
                        HStack {
                            TextField("Key path", text: $keyPath,
                                      prompt: Text("~/.ssh/id_ed25519"))
                            Button("Choose…") { chooseKeyFile() }
                        }
                        RevealableSecretField(label: "Passphrase (if encrypted)", text: $passphrase)
                    }
                }
                Section {
                    Text("Assign this login to a session with its Login picker, or "
                         + "make it a group's default. Editing it here updates every "
                         + "session that uses it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || username.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
        .onAppear(perform: load)
    }

    private func load() {
        guard let c = original else { return }
        name = c.name
        username = c.username
        authType = c.authType == "keyfile" ? "keyfile" : "password"
        password = c.password ?? ""
        keyPath = c.keyPath ?? ""
        passphrase = c.passphrase ?? ""
        domain = c.domain ?? ""
    }

    private func save() {
        let credential = CredentialConfig(
            id: original?.id ?? UUID().uuidString,
            name: name,
            username: username,
            authType: authType,
            password: authType == "password" && !password.isEmpty ? password : nil,
            keyPath: authType == "keyfile" && !keyPath.isEmpty ? keyPath : nil,
            keyData: nil,
            passphrase: authType == "keyfile" && !passphrase.isEmpty ? passphrase : nil,
            domain: domain.isEmpty ? nil : domain)
        onSave(credential)
        dismiss()
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path
        }
    }
}

/// Macro editor — a saved command snippet, MobaXterm's macro.
struct MacroEditView: View {
    @Environment(\.dismiss) private var dismiss
    let original: MacroConfig?
    let onSave: (MacroConfig) -> Void

    @State private var name = ""
    @State private var command = ""
    @State private var sendReturn = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Macro") {
                    TextField("Name", text: $name, prompt: Text("restart nginx"))
                }
                Section("Command") {
                    // Plain TextEditor rather than a Form row: macros are often
                    // several lines, and a TextField collapses them to one.
                    TextEditor(text: $command)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                    Toggle("Press Return after sending", isOn: $sendReturn)
                    Text(sendReturn
                         ? "Runs immediately in the focused terminal. Every line is its own command."
                         : "Types the text and stops, so you can check it before pressing Return.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Macros are stored in the encrypted vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    // No .defaultAction: Return belongs to the command editor.
                    .disabled(name.isEmpty || command.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 430)
        .onAppear(perform: load)
    }

    private func load() {
        guard let m = original else { return }
        name = m.name
        command = m.command
        sendReturn = m.sendReturn
    }

    private func save() {
        onSave(MacroConfig(
            id: original?.id ?? UUID().uuidString,
            name: name,
            command: command,
            sendReturn: sendReturn
        ))
        dismiss()
    }
}

/// Quick Connect (⌘K): type user@host:port and go, without saving a session.
struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    let onConnect: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Connect")
                .font(.headline)
            TextField("user@host:port", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(go)
            Text("Connects without saving. Omit user or port to use \(NSUserName()) and 22.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func go() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onConnect(value)
        dismiss()
    }
}

struct TunnelEditView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let original: TunnelConfig?
    let onSave: (TunnelConfig) -> Void

    @State private var name = ""
    @State private var type = "local"
    @State private var sessionId = ""
    @State private var bindPort = 8080
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = 80

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Port Forward") {
                    TextField("Name", text: $name, prompt: Text("db via bastion"))
                    Picker("Direction", selection: $type) {
                        Text("Local (-L): local port → remote target").tag("local")
                        Text("Remote (-R): server port → local target").tag("remote")
                        Text("Dynamic (-D): local SOCKS5 proxy").tag("dynamic")
                    }
                    .pickerStyle(.radioGroup)
                    Picker("Via session", selection: $sessionId) {
                        ForEach(tunnelHosts) { s in
                            Text(s.name).tag(s.id)
                        }
                    }
                    if tunnelHosts.isEmpty {
                        Text("A tunnel is carried by an SSH connection, and there is no "
                             + "SSH or Mosh session to carry it.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    TextField(type == "remote" ? "Port on server" : "Local port",
                              value: $bindPort, format: .number.grouping(.never))
                    if type != "dynamic" {
                        TextField(type == "local" ? "Target host (from server)" : "Target host (from this Mac)",
                                  text: $targetHost)
                        TextField("Target port", value: $targetPort, format: .number.grouping(.never))
                    } else {
                        Text("Point your browser/app at SOCKS5 127.0.0.1:\(String(bindPort)) — "
                             + "each request is tunnelled through this session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || sessionId.isEmpty || targetHost.isEmpty)
            }
            .padding(12)
        }
        // Tall enough for Target port to stay visible below the Direction radios.
        .frame(width: 440, height: 420)
        .onAppear(perform: load)
    }

    /// Only sessions that speak SSH: a remote desktop or a serial line cannot
    /// carry a forward, and offering them invites a tunnel that never starts.
    private var tunnelHosts: [SessionConfig] {
        TunnelHosts.eligible(in: app.data.sessions)
    }

    private func load() {
        if let t = original {
            name = t.name
            type = t.type
            // A tunnel saved before this was filtered may point at something
            // that cannot carry it. Blank it rather than show an empty picker
            // over a stale id: Save stays disabled until a real one is chosen.
            sessionId = TunnelHosts.isEligible(sessionID: t.sessionId, in: app.data.sessions)
                ? t.sessionId : ""
            bindPort = t.bindPort
            targetHost = t.targetHost
            targetPort = t.targetPort
        } else {
            sessionId = tunnelHosts.first?.id ?? ""
        }
    }

    private func save() {
        let config = TunnelConfig(
            id: original?.id ?? UUID().uuidString,
            name: name,
            type: type,
            sessionId: sessionId,
            bindHost: "127.0.0.1",
            bindPort: bindPort,
            targetHost: targetHost,
            targetPort: targetPort
        )
        onSave(config)
        dismiss()
    }
}

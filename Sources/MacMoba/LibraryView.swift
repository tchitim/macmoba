// The Library window (P1-4): the management home for the vault's supporting
// objects — macros, shared credentials, session templates. These used to live
// as three permanent sidebar sections, costing the high-frequency navigation
// (sessions) its space for objects edited once a month. Royal TSX keeps the
// navigation tree for connections and gives everything else its own place;
// this is that place.
//
// Running a macro is deliberately NOT here — that stays in the Macros menu
// (⌃⌘1–9) next to the terminal it fires into. The Library manages; it does
// not execute.

import MacMobaCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var app: AppState

    enum Category: String, CaseIterable, Identifiable {
        case macros, credentials, templates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .macros: return "Macros"
            case .credentials: return "Credentials"
            case .templates: return "Templates"
            }
        }
        var symbol: String {
            switch self {
            case .macros: return "bolt"
            case .credentials: return "key.fill"
            case .templates: return "doc.badge.plus"
            }
        }
    }

    @State private var category: Category? = .macros
    @State private var showNewMacro = false
    @State private var editingMacro: MacroConfig?
    @State private var showNewCredential = false
    @State private var editingCredential: CredentialConfig?
    @State private var showNewTemplate = false
    @State private var editingTemplate: SessionConfig?
    @State private var newFromTemplate: SessionConfig?

    private func count(_ c: Category) -> Int {
        switch c {
        case .macros: return app.data.macros.count
        case .credentials: return app.data.credentials.count
        case .templates: return app.data.templates.count
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Category.allCases, selection: $category) { c in
                HStack {
                    Label(c.title, systemImage: c.symbol)
                    Spacer()
                    Text("\(count(c))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(c)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
        } detail: {
            switch category ?? .macros {
            case .macros: macrosPane
            case .credentials: credentialsPane
            case .templates: templatesPane
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .navigationTitle("Library")
        .sheet(isPresented: $showNewMacro) {
            MacroEditView(original: nil) { app.upsertMacro($0) }
        }
        .sheet(item: $editingMacro) { macro in
            MacroEditView(original: macro) { app.upsertMacro($0) }
        }
        .sheet(isPresented: $showNewCredential) {
            CredentialEditView(original: nil) { app.upsertCredential($0) }
        }
        .sheet(item: $editingCredential) { credential in
            CredentialEditView(original: credential) { app.upsertCredential($0) }
        }
        .sheet(isPresented: $showNewTemplate) {
            SessionEditView(original: nil, isTemplate: true) { app.upsertTemplate($0) }
        }
        .sheet(item: $editingTemplate) { template in
            SessionEditView(original: template, isTemplate: true) { app.upsertTemplate($0) }
        }
        // Creating a session from a template opens the normal editor,
        // pre-filled, so the host and name can be finished before saving.
        .sheet(item: $newFromTemplate) { draft in
            SessionEditView(original: draft) { app.upsertSession($0) }
        }
    }

    // MARK: - Macros

    private var macrosPane: some View {
        objectList(
            isEmpty: app.data.macros.isEmpty,
            emptyText: "No macros yet. A macro types a saved command into the "
                + "focused terminal — or every terminal, with MultiExec on.",
            addTitle: "New Macro…",
            addAction: { showNewMacro = true }
        ) {
            ForEach(Array(app.data.macros.enumerated()), id: \.element.id) { index, macro in
                HStack(spacing: 8) {
                    Image(systemName: "bolt").foregroundStyle(.yellow).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(macro.name)
                        Text(macro.command)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if index < 9 {
                        Text("⌃⌘\(index + 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editingMacro = macro }
                .contextMenu {
                    Button("Edit…") { editingMacro = macro }
                    Divider()
                    Button("Move Up") { app.moveMacro(macro, by: -1) }
                        .disabled(index == 0)
                    Button("Move Down") { app.moveMacro(macro, by: 1) }
                        .disabled(index == app.data.macros.count - 1)
                    Divider()
                    Button("Delete", role: .destructive) { app.deleteMacro(macro) }
                }
            }
        }
    }

    // MARK: - Credentials

    private var credentialsPane: some View {
        objectList(
            isEmpty: app.data.credentials.isEmpty,
            emptyText: "No shared logins yet. A credential is one login reused "
                + "by many sessions — set it here once, pick it in a session's "
                + "Login category.",
            addTitle: "New Credential…",
            addAction: { showNewCredential = true }
        ) {
            ForEach(app.data.credentials) { credential in
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.orange).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(credential.name)
                        Text(credential.username.isEmpty ? "no username" : credential.username)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editingCredential = credential }
                .contextMenu {
                    Button("Edit…") { editingCredential = credential }
                    Divider()
                    Button("Delete", role: .destructive) { app.deleteCredential(credential) }
                }
            }
        }
    }

    // MARK: - Templates

    private var templatesPane: some View {
        objectList(
            isEmpty: app.data.templates.isEmpty,
            emptyText: "No templates yet. A template is a session blueprint — "
                + "\"New from template\" copies it, replacement tokens filled in.",
            addTitle: "New Template…",
            addAction: { showNewTemplate = true }
        ) {
            ForEach(app.data.templates) { template in
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus").foregroundStyle(.teal).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(template.name)
                        Text(template.sessionKind.displayName
                             + (template.host.isEmpty ? "" : " · \(template.host)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { newFromTemplate = app.sessionFromTemplate(template) }
                .contextMenu {
                    Button("New Session from This") {
                        newFromTemplate = app.sessionFromTemplate(template)
                    }
                    Button("Edit Template…") { editingTemplate = template }
                    Divider()
                    Button("Delete", role: .destructive) { app.deleteTemplate(template) }
                }
                .help("Double-click to create a session from this template")
            }
        }
    }

    // MARK: - shared scaffolding

    /// One pane = a list of objects with a footer "add" button, or a centred
    /// explanation when there are none yet.
    @ViewBuilder
    private func objectList<Rows: View>(
        isEmpty: Bool, emptyText: String, addTitle: String,
        addAction: @escaping () -> Void, @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(spacing: 0) {
            if isEmpty {
                Spacer()
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Spacer()
            } else {
                List { rows() }
            }
            Divider()
            HStack {
                Button(addTitle, action: addAction)
                Spacer()
            }
            .padding(10)
        }
    }
}

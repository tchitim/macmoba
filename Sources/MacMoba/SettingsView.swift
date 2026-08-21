// Settings (⌘,) — currently terminal appearance and session logging.

import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var clipboard = ClipboardPrefs.shared
    @State private var logPath = SessionLogger.directory.path

    // Standard macOS settings tabs (P2-7): one page per topic at a fixed
    // height, instead of one long scrolling form.
    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            terminalTab
                .tabItem { Label("Terminal", systemImage: "terminal") }
            logsTab
                .tabItem { Label("Logs", systemImage: "doc.text") }
        }
        .frame(width: 480, height: 360)
        .onAppear { logPath = SessionLogger.directory.path }
    }

    private var generalTab: some View {
        Form {
            Section("Startup & sleep") {
                Toggle("Reopen last session's tabs on launch",
                       isOn: $app.reopenSessionsOnLaunch)
                Toggle("Reconnect after the Mac wakes from sleep",
                       isOn: $app.reconnectAfterSleep)
                Text("On launch the tabs you had open are reopened and connect "
                     + "as usual. After sleep, terminal sessions that dropped are "
                     + "redialled; ones that survived are left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Macros") {
                Toggle("Confirm before a macro runs on every session",
                       isOn: $app.confirmBroadcastMacros)
                Text("Only asked when MultiExec (⇧⌘B) is on and more than one "
                     + "session is connected — a macro then runs on all of them "
                     + "from a single ⌃⌘n, with no prompt in between.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var terminalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $app.themeID) {
                    Text("Auto (match system)").tag(TerminalTheme.autoID)
                    Divider()
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                // Said out loud because its absence reads as a bug: pick a
                // theme while looking at a remote desktop and nothing happens.
                Text("Colours the terminal. Remote desktops and web pages keep their own; "
                     + "the sidebar and window follow the system.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Scrollback")
                    Spacer()
                    Stepper(value: Binding(
                        get: { app.terminalScrollback },
                        set: { app.terminalScrollback = $0 }
                    ), in: 500...100_000, step: 5_000) {
                        Text("\(app.terminalScrollback) lines")
                            .monospacedDigit()
                    }
                }
                Text("Applies to sessions opened from now on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Font size")
                    Spacer()
                    Stepper(value: Binding(
                        get: { app.terminalFontSize },
                        set: { app.terminalFontSize = min(32, max(8, $0)) }
                    ), in: 8...32, step: 1) {
                        Text("\(Int(app.terminalFontSize)) pt")
                            .monospacedDigit()
                    }
                }
            }
            Section("Copy & paste") {
                Toggle("Copy on select", isOn: $clipboard.copyOnSelect)
                Toggle("Right-click and middle-click paste", isOn: $clipboard.mousePaste)
                Toggle("Warn before pasting multiple lines", isOn: $clipboard.warnMultilinePaste)
                Text("With the warning off, a paste containing newlines runs each "
                     + "line as its own command the moment it arrives. "
                     + "⇧⌘V pastes joined into a single line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var logsTab: some View {
        Form {
            Section("Session logs") {
                HStack {
                    TextField("Folder", text: $logPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyPath)
                    Button("Choose…") { chooseFolder() }
                }
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(SessionLogger.directory)
                    }
                    Button("Use Default") {
                        SessionLogger.setDirectory(nil)
                        logPath = SessionLogger.defaultDirectory.path
                    }
                    Spacer()
                }
                Text("Logs are written 0600 (owner-only) — session output can "
                     + "contain anything the server printed. Changing this affects "
                     + "new logs; files already written stay where they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func applyPath() {
        let expanded = (logPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            SessionLogger.setDirectory(nil)
            logPath = SessionLogger.defaultDirectory.path
            return
        }
        SessionLogger.setDirectory(URL(fileURLWithPath: expanded, isDirectory: true))
        logPath = expanded
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = SessionLogger.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SessionLogger.setDirectory(url)
        logPath = url.path
    }
}

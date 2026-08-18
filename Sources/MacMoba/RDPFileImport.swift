// Opening a Microsoft .rdp connection file.
//
// The common source is a privileged-access system — CyberArk PSM hands out a
// freshly generated .rdp per session — so this deliberately does NOT silently
// save the file as a session: it shows what was in it, says what could not be
// carried across, and lets the user connect once or keep it.

import AppKit
import MacMobaCore
import UniformTypeIdentifiers

@MainActor
enum RDPFileImport {
    /// Ask for a file and open it.
    static func chooseAndOpen(into app: AppState, window: WindowState?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "rdp") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.prompt = "Open"
        panel.message = "Choose a Remote Desktop connection file (.rdp)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, into: app, window: window)
    }

    /// Open a file chosen anywhere — the panel, or a double-click in Finder.
    static func open(_ url: URL, into app: AppState, window: WindowState?) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            app.lastError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        let file = RDPFileParser.parse(data)
        let name = url.deletingPathExtension().lastPathComponent
        var (config, warnings) = RDPFileParser.session(from: file, name: name)

        guard !config.host.isEmpty else {
            app.lastError = "\(url.lastPathComponent) has no \"full address\", so there is "
                + "nothing to connect to. If it came from a portal, it may have expired."
            return
        }

        // A fresh id every time: these files are handed out per session, and
        // re-importing one should not quietly overwrite a saved session.
        config.id = UUID().uuidString
        present(config: config, warnings: warnings, fileName: url.lastPathComponent,
                hasEncryptedPassword: file.settings["password 51"] != nil,
                into: app, window: window)
    }

    private static func present(config: SessionConfig, warnings: [String], fileName: String,
                                hasEncryptedPassword: Bool,
                                into app: AppState, window: WindowState?) {
        let alert = NSAlert()
        alert.messageText = "Open \(config.name)?"
        var lines = ["\(config.username.isEmpty ? "" : config.username + "@")"
                     + "\(config.host):\(config.port)"]
        if let domain = config.domain, !domain.isEmpty { lines.append("Domain: \(domain)") }
        lines.append(contentsOf: warnings)
        // Only say something about the password when there is something to
        // say. A file with no password at all just connects.
        if hasEncryptedPassword {
            lines.append("The saved password cannot be read on a Mac, so you will be "
                         + "asked for it.")
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Save Session")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            connect(config, hasEncryptedPassword: hasEncryptedPassword,
                    into: app, window: window)
        case .alertSecondButtonReturn:
            save(config, into: app)
        default:
            break
        }
    }

    private static func connect(_ config: SessionConfig, hasEncryptedPassword: Bool,
                                into app: AppState, window: WindowState?) {
        var config = config
        // Asking for a password the file never had is pure friction: a PSM
        // file carries a one-time token as the user name and no password, and
        // Remote Desktop does not prompt for one either. Whether an empty
        // password is acceptable is the server's decision — if it refuses, the
        // tab says so and the session can be saved and edited to add one.
        //
        // A DPAPI blob is different: the file DOES have a password, we simply
        // cannot read it, so there is a real question to ask.
        if hasEncryptedPassword {
            guard let password = askForPassword(for: config,
                                                hasEncryptedPassword: true) else { return }
            config.password = password
        }
        // Opened, not saved: a per-session file from a privileged-access
        // system is not something to leave lying in the vault by default.
        window?.openTab(for: config)
    }

    private static func save(_ config: SessionConfig, into app: AppState) {
        guard (try? app.vault.getData()) != nil else {
            app.lastError = "Unlock the vault before saving a session."
            return
        }
        app.upsertSession(config)
    }

    private static func askForPassword(for config: SessionConfig,
                                       hasEncryptedPassword: Bool) -> String? {
        let alert = NSAlert()
        // A PSM token is a 40-character GUID; putting it in the title wraps to
        // three lines and buries the actual question.
        let isToken = config.username.hasPrefix("PSM@")
        alert.messageText = isToken ? "Password for the PSM connection"
            : "Password for \(config.username.isEmpty ? config.host : config.username)"

        var lines: [String] = []
        if hasEncryptedPassword {
            lines.append("The password saved in this file is encrypted by Windows (DPAPI) "
                         + "and cannot be read on a Mac, so it has to be typed here.")
        } else {
            // Which is the case for a PSM-issued file: it carries a one-time
            // token as the user name and no password at all.
            lines.append("This connection file does not include a password — "
                         + "type the one you would use in Remote Desktop. "
                         + "If the connection needs no password, leave it empty.")
        }
        lines.append("Connecting to \(config.host):\(config.port)"
                     + (config.domain.map { " as \($0)\\\(config.username)" }
                        ?? " as \(config.username)"))
        alert.informativeText = lines.joined(separator: "\n\n")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

// Export / import UI.
//
// Two panels and a password prompt. The interesting part is that "include
// passwords" and "encrypt" are not separate choices: keeping the secrets forces
// encryption, because a readable file full of credentials is the failure mode
// this whole feature could easily become.

import AppKit
import MacMobaCore
import SwiftUI
import UniformTypeIdentifiers

enum SessionTransfer {

    // MARK: - Export

    @MainActor
    static func export(from app: AppState) {
        let data: VaultData
        do {
            data = try app.vault.getData()
        } catch {
            app.lastError = "Unlock the vault before exporting."
            return
        }

        let choice = NSAlert()
        choice.messageText = "Export \(data.sessions.count) sessions?"
        choice.informativeText =
            "Passwords and key passphrases are left out unless you choose to include them. "
            + "An export that includes them is always encrypted with a password you set."
        choice.addButton(withTitle: "Export Without Passwords")
        choice.addButton(withTitle: "Include Passwords…")
        choice.addButton(withTitle: "Cancel")
        let response = choice.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let includeSecrets = response == .alertSecondButtonReturn

        var password: String?
        if includeSecrets {
            guard let entered = askForPassword(
                title: "Password for this export",
                message: "The file is encrypted with this password. There is no way to "
                       + "recover its contents without it.",
                confirming: true)
            else { return }
            password = entered
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = includeSecrets
            ? "MacMoba-sessions-encrypted.json" : "MacMoba-sessions.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let archive = SessionExport.archive(from: data, includeSecrets: includeSecrets,
                                                now: Date())
            let encoded = includeSecrets
                ? try SessionExport.encrypted(archive, password: password ?? "")
                : try SessionExport.plainJSON(archive)
            try encoded.write(to: url, options: .atomic)
            // An export with credentials in it should not be world-readable,
            // even though it is encrypted.
            if includeSecrets {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: url.path)
            }
            app.infoMessage = "Exported \(archive.sessions.count) sessions to "
                            + "\(url.lastPathComponent)."
        } catch {
            app.lastError = "Could not write the export: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    @MainActor
    static func importSessions(into app: AppState) {
        guard (try? app.vault.getData()) != nil else {
            app.lastError = "Unlock the vault before importing."
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let raw = try Data(contentsOf: url)
            var password: String?
            if SessionExport.isEncrypted(raw) {
                guard let entered = askForPassword(
                    title: "Password for \(url.lastPathComponent)",
                    message: "This export is encrypted.",
                    confirming: false)
                else { return }
                password = entered
            }
            let archive = try SessionExport.read(raw, password: password)
            let existing = try app.vault.getData()
            let additive = SessionImport.merge(archive, into: existing, mode: .additive)
            let updating = SessionImport.merge(archive, into: existing, mode: .update)

            guard additive.added > 0 || updating.updated > 0 else {
                app.infoMessage = "Nothing to import — everything in that file is already here."
                return
            }

            let secretsNote = archive.includesSecrets ? ""
                : "\n\nThis export carries no passwords, so new sessions will need "
                + "theirs filled in (existing passwords are kept)."

            let confirm = NSAlert()
            let chosen: SessionImport.Result
            if updating.updated > 0 {
                // The archive has edits to sessions already here — let the user
                // choose between a safe add-only import and pulling the edits in.
                confirm.messageText = "\(additive.added) new, \(updating.updated) changed"
                confirm.informativeText =
                    "This file has \(additive.added) new item(s) and \(updating.updated) "
                    + "update(s) to sessions you already have." + secretsNote
                confirm.addButton(withTitle: "Add & Update")
                confirm.addButton(withTitle: "Add New Only")
                confirm.addButton(withTitle: "Cancel")
                switch confirm.runModal() {
                case .alertFirstButtonReturn: chosen = updating
                case .alertSecondButtonReturn:
                    guard additive.added > 0 else {
                        app.infoMessage = "No new items to add."
                        return
                    }
                    chosen = additive
                default: return
                }
            } else {
                confirm.messageText = "Import \(additive.added) items?"
                var detail = "\(additive.added) new to add"
                if additive.skipped > 0 { detail += ", \(additive.skipped) already here and left alone" }
                detail += "." + secretsNote
                confirm.informativeText = detail
                confirm.addButton(withTitle: "Import")
                confirm.addButton(withTitle: "Cancel")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
                chosen = additive
            }

            try app.vault.save(chosen.data)
            app.data = chosen.data
            let summary = chosen.updated > 0
                ? "Imported \(chosen.added) new, updated \(chosen.updated)."
                : "Imported \(chosen.added) items."
            app.infoMessage = summary
        } catch {
            app.lastError = "Could not import: \(error.localizedDescription)"
        }
    }

    // MARK: - Password prompt

    @MainActor
    private static func askForPassword(title: String, message: String,
                                       confirming: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Password"
        if confirming {
            let confirmField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            confirmField.placeholderString = "Confirm password"
            // A plain frame-based container, not NSStackView: the stack view is
            // auto-layout driven and collapses frame-sized subviews to nothing,
            // which rendered both fields as unusable slivers.
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
            confirmField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            field.frame = NSRect(x: 0, y: 32, width: 260, height: 24)
            container.addSubview(field)
            container.addSubview(confirmField)
            alert.accessoryView = container
            alert.window.initialFirstResponder = field

            while alert.runModal() == .alertFirstButtonReturn {
                let entered = field.stringValue
                if entered.isEmpty {
                    field.placeholderString = "Password cannot be empty"
                    continue
                }
                if entered != confirmField.stringValue {
                    // Losing an export to a typo is worse than asking again:
                    // there is nothing to fall back on if the password is wrong.
                    confirmField.stringValue = ""
                    confirmField.placeholderString = "Passwords did not match — try again"
                    continue
                }
                return entered
            }
            return nil
        }

        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

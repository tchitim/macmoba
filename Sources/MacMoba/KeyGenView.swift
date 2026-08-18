// Generate an SSH keypair, MobaKeyGen-style: pick a type, optionally a
// passphrase, and get back a private key to save and a public key to paste into
// authorized_keys. The heavy lifting is in MacMobaCore.SSHKeyGenerator; this is
// just the panel and the save/copy plumbing.

import AppKit
import MacMobaCore
import SwiftUI
import UniformTypeIdentifiers

struct KeyGenView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var type: SSHKeyType = .ed25519
    @State private var comment = defaultComment()
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var generated: GeneratedKey?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate SSH Key").font(.headline)

            Form {
                Picker("Type", selection: $type) {
                    ForEach(SSHKeyType.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Comment", text: $comment, prompt: Text("user@host"))
                SecureField("Passphrase (optional)", text: $passphrase)
                if !passphrase.isEmpty {
                    SecureField("Confirm passphrase", text: $confirm)
                }
            }
            // Regenerating on a settings change would be surprising; the button
            // is the one place a key is minted.
            .onChange(of: type) { _ in generated = nil }

            if let key = generated {
                Divider()
                Text("Public key").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    Text(key.publicKeyLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                .frame(height: 20)
                Text(key.fingerprint)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Copy Public Key") { copy(key.publicKeyLine) }
                    Button("Save Private Key…") { savePrivateKey(key) }
                    Spacer()
                }
            }

            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!passphrase.isEmpty && passphrase != confirm)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func generate() {
        // Guarded by the button, but re-check so a mismatch can never slip out.
        guard passphrase.isEmpty || passphrase == confirm else {
            note = "Passphrases do not match."
            return
        }
        generated = SSHKeyGenerator.generate(
            type: type,
            comment: comment.trimmingCharacters(in: .whitespaces),
            passphrase: passphrase.isEmpty ? nil : passphrase)
        note = passphrase.isEmpty
            ? "Generated. Save the private key somewhere safe."
            : "Generated (passphrase-protected)."
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note = "Public key copied to the clipboard."
    }

    private func savePrivateKey(_ key: GeneratedKey) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename()
        panel.message = "The matching public key is saved alongside as .pub"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try key.privateKeyPEM.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            let pub = url.appendingPathExtension("pub")
            try (key.publicKeyLine + "\n").write(to: pub, atomically: true, encoding: .utf8)
            note = "Saved \(url.lastPathComponent) and \(pub.lastPathComponent)."
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
    }

    private func suggestedFilename() -> String {
        switch type {
        case .ed25519: return "id_ed25519"
        case .ecdsaP256, .ecdsaP384, .ecdsaP521: return "id_ecdsa"
        }
    }

    private static func defaultComment() -> String {
        let user = NSUserName()
        let host = Host.current().localizedName ?? "mac"
        return "\(user)@\(host)"
    }
}

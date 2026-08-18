// Exporting and importing sessions, for moving to another Mac.
//
// The whole design turns on one question: what happens to the passwords and
// key passphrases? A plain JSON file full of credentials is the sort of thing
// that ends up in a Downloads folder, a chat message, or a backup — so secrets
// are stripped by default, and an export that keeps them is *always* encrypted
// with a password the user types. There is no "plain text with secrets" option
// because there is no good reason to want one.

import Crypto
import Foundation

public struct SessionArchive: Codable, Equatable, Sendable {
    /// Bumped only for changes an older build could not read.
    public static let currentVersion = 1

    /// Positive identification. Every other field is optional so that older
    /// files keep decoding, which means without this a bare `{}` would decode
    /// into a perfectly valid empty archive and "import" would silently accept
    /// any JSON at all.
    public var macmoba: String
    public var version: Int
    public var exportedAt: Date
    public var sessions: [SessionConfig]
    public var tunnels: [TunnelConfig]
    public var macros: [MacroConfig]
    /// Whether passwords and passphrases survived the export. Recorded so the
    /// import side can say what it is about to bring in.
    public var includesSecrets: Bool

    public static let marker = "session-export"

    public init(macmoba: String = SessionArchive.marker,
                version: Int = SessionArchive.currentVersion,
                exportedAt: Date,
                sessions: [SessionConfig] = [],
                tunnels: [TunnelConfig] = [],
                macros: [MacroConfig] = [],
                includesSecrets: Bool = false) {
        self.macmoba = macmoba
        self.version = version
        self.exportedAt = exportedAt
        self.sessions = sessions
        self.tunnels = tunnels
        self.macros = macros
        self.includesSecrets = includesSecrets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macmoba = try container.decodeIfPresent(String.self, forKey: .macmoba) ?? ""
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date(timeIntervalSince1970: 0)
        sessions = try container.decodeIfPresent([SessionConfig].self, forKey: .sessions) ?? []
        tunnels = try container.decodeIfPresent([TunnelConfig].self, forKey: .tunnels) ?? []
        macros = try container.decodeIfPresent([MacroConfig].self, forKey: .macros) ?? []
        includesSecrets = try container.decodeIfPresent(Bool.self, forKey: .includesSecrets) ?? false
    }
}

public enum SessionArchiveError: Error, Equatable, LocalizedError {
    case wrongPassword
    case notAnArchive
    case tooNew(Int)

    public var errorDescription: String? {
        switch self {
        case .wrongPassword:
            return "That password does not open this file."
        case .notAnArchive:
            return "This is not a MacMoba session export."
        case .tooNew(let version):
            return "This export was written by a newer version of MacMoba "
                 + "(format \(version)). Update MacMoba to import it."
        }
    }
}

public enum SessionExport {
    /// Credential fields, blanked when exporting without secrets.
    ///
    /// Note this covers the key *passphrase* and inline key material too, not
    /// just `password` — an export that quietly carried a decrypted private key
    /// would be worse than one that carried a password.
    public static func stripSecrets(from session: SessionConfig) -> SessionConfig {
        var copy = session
        copy.password = nil
        copy.passphrase = nil
        copy.keyData = nil
        // keyPath is a path, not a secret, and is what makes the session still
        // usable on a machine where the key already exists.
        return copy
    }

    public static func stripSecrets(from macro: MacroConfig) -> MacroConfig { macro }

    /// Builds an archive from vault contents.
    public static func archive(from data: VaultData, includeSecrets: Bool,
                               now: Date) -> SessionArchive {
        SessionArchive(
            exportedAt: now,
            sessions: includeSecrets ? data.sessions : data.sessions.map(stripSecrets(from:)),
            tunnels: data.tunnels,
            macros: data.macros,
            includesSecrets: includeSecrets
        )
    }

    /// Plain, readable JSON. Only ever used for an archive without secrets —
    /// `encrypted(_:password:)` is the only way to export credentials.
    public static func plainJSON(_ archive: SessionArchive) throws -> Data {
        precondition(!archive.includesSecrets,
                     "an archive with secrets must not be written unencrypted")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    /// scrypt + AES-256-GCM, the same envelope the vault itself uses.
    public static func encrypted(_ archive: SessionArchive, password: String) throws -> Data {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = try Vault.deriveKey(password: password, salt: salt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(archive)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce())
        let envelope = Envelope(
            macmoba: "session-export",
            v: SessionArchive.currentVersion,
            kdf: "scrypt",
            salt: salt.base64EncodedString(),
            iv: Data(sealed.nonce).base64EncodedString(),
            tag: sealed.tag.base64EncodedString(),
            ct: sealed.ciphertext.base64EncodedString()
        )
        let out = JSONEncoder()
        out.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try out.encode(envelope)
    }

    /// Reads either form. `password` is only consulted for an encrypted file,
    /// and a file being encrypted is discoverable without it — so the UI can
    /// ask for a password only when one is actually needed.
    public static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data)) != nil
    }

    public static func read(_ data: Data, password: String?) throws -> SessionArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            guard let password else { throw SessionArchiveError.wrongPassword }
            guard let salt = Data(base64Encoded: envelope.salt),
                  let iv = Data(base64Encoded: envelope.iv),
                  let tag = Data(base64Encoded: envelope.tag),
                  let ciphertext = Data(base64Encoded: envelope.ct)
            else { throw SessionArchiveError.notAnArchive }
            guard envelope.v <= SessionArchive.currentVersion else {
                throw SessionArchiveError.tooNew(envelope.v)
            }
            let key = try Vault.deriveKey(password: password, salt: salt)
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                            ciphertext: ciphertext, tag: tag)
            guard let plaintext = try? AES.GCM.open(box, using: key) else {
                // A wrong password and a tampered file are indistinguishable
                // here, and both mean "this did not open".
                throw SessionArchiveError.wrongPassword
            }
            return try decoder.decode(SessionArchive.self, from: plaintext)
        }

        guard let archive = try? decoder.decode(SessionArchive.self, from: data),
              archive.macmoba == SessionArchive.marker
        else { throw SessionArchiveError.notAnArchive }
        guard archive.version <= SessionArchive.currentVersion else {
            throw SessionArchiveError.tooNew(archive.version)
        }
        return archive
    }

    private struct Envelope: Codable {
        /// Marks the file as ours before anything is decrypted.
        var macmoba: String
        var v: Int
        var kdf: String
        var salt: String
        var iv: String
        var tag: String
        var ct: String
    }
}

public enum SessionImport {
    public struct Result: Equatable {
        public var added: Int
        /// Existing sessions refreshed from the archive (only in `.update` mode).
        public var updated: Int
        public var skipped: Int
        public var data: VaultData

        public init(added: Int = 0, updated: Int = 0, skipped: Int = 0, data: VaultData) {
            self.added = added
            self.updated = updated
            self.skipped = skipped
            self.data = data
        }
    }

    /// How a merge treats an archive entry that already exists locally.
    public enum Mode: Equatable, Sendable {
        /// Never touch what is already configured — a one-time, safe import.
        case additive
        /// Also refresh matched sessions from the archive, for pulling a
        /// teammate's edits. Local secrets are preserved when the archive was
        /// exported without them, so an update never blanks a saved password.
        case update
    }

    /// Merges an archive into existing vault contents.
    ///
    /// In `.additive` mode (the default) existing entries are never overwritten,
    /// so a mistaken import cannot destroy what is already configured. Identity
    /// is by id first — re-importing the same file twice changes nothing — and
    /// then by what the session actually points at, so a session copied between
    /// machines is not duplicated just because it was given a fresh id.
    ///
    /// In `.update` mode a session that matches an existing one *by id* is
    /// refreshed from the archive (this is the ongoing team-sync case), while
    /// new ones are still added and target-only matches are still skipped.
    public static func merge(_ archive: SessionArchive, into existing: VaultData,
                             mode: Mode = .additive) -> Result {
        var data = existing
        var added = 0
        var updated = 0
        var skipped = 0

        let existingByID = Dictionary(existing.sessions.map { ($0.id, $0) },
                                      uniquingKeysWith: { a, _ in a })
        let indexByID = Dictionary(data.sessions.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { a, _ in a })
        var seenTargets = Set(existing.sessions.map(target(of:)))
        for session in archive.sessions {
            if let local = existingByID[session.id] {
                // Same session, already here. Refresh it in update mode.
                if mode == .update, let i = indexByID[session.id] {
                    data.sessions[i] = reconcile(incoming: session, local: local,
                                                 archiveHasSecrets: archive.includesSecrets)
                    updated += 1
                } else {
                    skipped += 1
                }
                continue
            }
            if seenTargets.contains(target(of: session)) {
                // A copy of something we have under a different id — leave it.
                skipped += 1
                continue
            }
            seenTargets.insert(target(of: session))
            data.sessions.append(session)
            added += 1
        }

        let macroIDs = Set(existing.macros.map(\.id))
        var macroNames = Set(existing.macros.map(\.name))
        for macro in archive.macros where !macroIDs.contains(macro.id)
            && !macroNames.contains(macro.name) {
            macroNames.insert(macro.name)
            data.macros.append(macro)
            added += 1
        }

        let tunnelIDs = Set(existing.tunnels.map(\.id))
        for tunnel in archive.tunnels where !tunnelIDs.contains(tunnel.id) {
            data.tunnels.append(tunnel)
            added += 1
        }

        return Result(added: added, updated: updated, skipped: skipped, data: data)
    }

    /// Take the incoming session, but never blank a saved secret with an empty
    /// one from a secret-stripped export — the local password/passphrase stays.
    private static func reconcile(incoming: SessionConfig, local: SessionConfig,
                                  archiveHasSecrets: Bool) -> SessionConfig {
        guard !archiveHasSecrets else { return incoming }
        var merged = incoming
        if (merged.password?.isEmpty ?? true) { merged.password = local.password }
        if (merged.passphrase?.isEmpty ?? true) { merged.passphrase = local.passphrase }
        if (merged.keyData?.isEmpty ?? true) { merged.keyData = local.keyData }
        return merged
    }

    private static func target(of session: SessionConfig) -> String {
        "\(session.sessionKind.rawValue)|\(session.username)@\(session.host):\(session.port)"
    }
}

// Pasting an image into a REMOTE terminal (the cmux workflow, SSH edition).
//
// A local terminal can hand an agent a screenshot by writing a temp file and
// typing its path. Over SSH the file has to exist on the far machine first —
// so: upload the bytes over the session's own SFTP subsystem (same
// credentials, same jump chain) into ~/.macmoba/, and give back the remote
// path for the caller to type into the prompt. Claude Code on the remote
// reads the image from that path.

import Foundation

/// Which pasted images have outlived their welcome.
///
/// Nothing used to remove these, so `~/.macmoba` on a machine you paste into
/// grows forever — thirty files and 9.6MB on the author's own after a
/// fortnight, none of them distinguishable from the outside.
///
/// Split out from the upload so the rule can be tested without a server, and
/// because deciding what to delete on someone else's machine deserves to be
/// readable on its own.
/// A session's own folder under `~/.macmoba`, so two sessions on the SAME
/// machine do not share a pot.
///
/// They otherwise do: connecting to one host from two tabs means one home
/// directory and one `~/.macmoba`, so a screenshot pasted in one session sits
/// among screenshots from every other — which is how someone working in one
/// session found files they had pasted in another and could not tell where any
/// of them came from.
public enum RemotePasteFolder {
    /// Turns a session name into one path segment.
    ///
    /// Deliberately strict rather than clever. The name comes from the vault
    /// and is used to build a path on a remote machine, so anything that is
    /// not a letter, digit, dash, underscore or dot becomes a dash — that
    /// rules out separators, spaces, quoting problems and `..` in one pass
    /// instead of enumerating what to forbid.
    public static func slug(for name: String) -> String {
        let kept = name.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." ? ch : "-"
        }
        var slug = String(kept)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        // A name that survives none of that would otherwise produce an empty
        // segment and a path ending in a slash.
        return slug.isEmpty ? "session" : String(slug.prefix(64))
    }
}

public enum RemotePasteRetention {
    public static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Names safe to delete: ours, and older than `maxAge`.
    ///
    /// Deliberately narrow. Only `paste-<digits>.png` is considered — exactly
    /// the shape this file writes — so anything else that happens to live in
    /// that directory is left alone no matter how old it is. A name that does
    /// not parse is kept rather than guessed about.
    ///
    /// Age comes from the timestamp in the name rather than the file's mtime:
    /// that is the moment of the paste, it is what this code chose, and it
    /// cannot be moved by a later transfer touching the file.
    public static func expired(names: [String], now: Date,
                               maxAge: TimeInterval = defaultMaxAge) -> [String] {
        let cutoff = now.timeIntervalSince1970 - maxAge
        return names.filter { name in
            guard name.hasPrefix("paste-"), name.hasSuffix(".png") else { return false }
            let digits = name.dropFirst("paste-".count).dropLast(".png".count)
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
                  let stamp = TimeInterval(digits) else { return false }
            return stamp < cutoff
        }
    }
}

public enum RemotePasteUpload {
    /// Upload `data` and return the remote path it landed on.
    ///
    /// `directory` defaults to `<remote home>/.macmoba` (created if missing) —
    /// the server's `realpath(".")` names the home directory, since an SFTP
    /// session starts there. Tests point it somewhere observable instead.
    public static func upload(
        data: Data,
        fileName: String,
        config: SessionConfig,
        jumps: [SessionConfig] = [],
        hostKeys: HostKeyVerification? = nil,
        directory: String? = nil
    ) async throws -> String {
        let client = try await SFTPClient.connect(config: config, via: jumps,
                                                  hostKeys: hostKeys)
        defer { client.close() }

        let dir: String
        if let directory {
            dir = directory
        } else {
            // Per session, so two tabs onto the same host keep their pastes
            // apart; see RemotePasteFolder.
            dir = try await client.realpath(".") + "/.macmoba/"
                + RemotePasteFolder.slug(for: config.name)
        }
        // Already existing is fine; a real failure resurfaces at upload time
        // with a path in hand, which beats failing on EEXIST here. The parent
        // is created first because mkdir does not make intermediates.
        if let slash = dir.lastIndex(of: "/"), directory == nil {
            try? await client.mkdir(String(dir[dir.startIndex..<slash]))
        }
        try? await client.mkdir(dir)

        let remotePath = dir + "/" + fileName
        // SFTPClient uploads from a file, so stage the bytes locally first.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-paste-\(UUID().uuidString)")
        try data.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await client.upload(localURL: staging, to: remotePath)

        // Sweep old pastes, best effort and only after the upload has
        // succeeded: losing an image because tidying failed would be a poor
        // trade, and a sweep that runs first could delete the only copy of
        // something if the upload then fails.
        await sweepExpired(in: dir, using: client, keeping: fileName)
        // Also the folder above, where every paste landed before sessions had
        // their own — otherwise those never expire.
        if let slash = dir.lastIndex(of: "/"), directory == nil {
            await sweepExpired(in: String(dir[dir.startIndex..<slash]), using: client)
        }
        return remotePath
    }

    /// Delete pasted images older than the retention window.
    ///
    /// Every failure is swallowed: this is housekeeping on someone else's
    /// machine, and no part of it is worth failing a paste over. A directory
    /// that cannot be listed, or a file that will not delete, simply stays.
    /// - Parameter keeping: a name the sweep must never delete.
    ///
    ///   The file just uploaded. Its stamp is always "now" in practice, so it
    ///   could not expire — but the sweep runs immediately after the upload,
    ///   and "this can delete the thing it was called to protect" is not a
    ///   property to leave resting on the caller's choice of filename. A test
    ///   using `paste-1.png` deleted its own upload and found this.
    static func sweepExpired(in directory: String, using client: SFTPClient,
                             now: Date = Date(),
                             maxAge: TimeInterval = RemotePasteRetention.defaultMaxAge,
                             keeping: String? = nil) async {
        guard let items = try? await client.list(directory) else { return }
        let doomed = RemotePasteRetention.expired(names: items.map(\.name),
                                                  now: now, maxAge: maxAge)
            .filter { $0 != keeping }
        for name in doomed {
            try? await client.removeFile(directory + "/" + name)
        }
    }
}

// Pasting an image into a REMOTE terminal (the cmux workflow, SSH edition).
//
// A local terminal can hand an agent a screenshot by writing a temp file and
// typing its path. Over SSH the file has to exist on the far machine first —
// so: upload the bytes over the session's own SFTP subsystem (same
// credentials, same jump chain) into ~/.macmoba/, and give back the remote
// path for the caller to type into the prompt. Claude Code on the remote
// reads the image from that path.

import Foundation

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
            dir = try await client.realpath(".") + "/.macmoba"
        }
        // Already existing is fine; a real failure resurfaces at upload time
        // with a path in hand, which beats failing on EEXIST here.
        try? await client.mkdir(dir)

        let remotePath = dir + "/" + fileName
        // SFTPClient uploads from a file, so stage the bytes locally first.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-paste-\(UUID().uuidString)")
        try data.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await client.upload(localURL: staging, to: remotePath)
        return remotePath
    }
}

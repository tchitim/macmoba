// This Mac, presented the same way a remote server is.
//
// The two-pane transfer view shows a local folder beside a remote one, and
// having both sides speak `RemoteFileService` means one pane view, one
// selection model and one transfer loop rather than a local variant of each.
// "Uploading" is then just copying from this service to the other one.

import Foundation

public final class LocalFileService: RemoteFileService, @unchecked Sendable {
    private let manager = FileManager.default

    public init() {}

    public func realpath(_ path: String) async throws -> String {
        if path == "." || path.isEmpty {
            return manager.homeDirectoryForCurrentUser.path
        }
        return (path as NSString).standardizingPath
    }

    public func list(_ path: String) async throws -> [SFTPItem] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .isHiddenKey]
        let contents = try manager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            // Hidden files are included deliberately: dotfiles are most of the
            // reason anyone opens a file browser on a server.
            options: [])
        return contents.compactMap { child -> SFTPItem? in
            let values = try? child.resourceValues(forKeys: Set(keys))
            var attributes = SFTPAttributes()
            let isDirectory = values?.isDirectory ?? false
            let isSymlink = values?.isSymbolicLink ?? false
            attributes.size = UInt64(values?.fileSize ?? 0)
            attributes.mtime = (values?.contentModificationDate)
                .map { UInt32(max(0, $0.timeIntervalSince1970)) }
            // Same shape the browser reads on the remote side: the type lives
            // in the top bits of the mode.
            let typeBits: UInt32 = isSymlink ? 0o120000 : (isDirectory ? 0o040000 : 0o100000)
            attributes.permissions = typeBits | (isDirectory ? 0o755 : 0o644)
            return SFTPItem(name: child.lastPathComponent, longname: child.lastPathComponent,
                            attributes: attributes)
        }
    }

    public func mkdir(_ path: String) async throws {
        try manager.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    public func removeFile(_ path: String) async throws {
        try manager.removeItem(atPath: path)
    }

    public func removeDirectoryRecursively(_ path: String) async throws {
        try manager.removeItem(atPath: path)
    }

    public func rename(_ oldPath: String, to newPath: String) async throws {
        try manager.moveItem(atPath: oldPath, toPath: newPath)
    }

    /// "Downloading" from this service means copying within the Mac.
    public func download(remotePath: String, to localURL: URL,
                         progress: (@Sendable (UInt64, UInt64?) -> Void)?) async throws {
        try copy(from: URL(fileURLWithPath: remotePath), to: localURL, progress: progress)
    }

    public func upload(localURL: URL, to remotePath: String,
                       progress: (@Sendable (UInt64, UInt64?) -> Void)?) async throws {
        try copy(from: localURL, to: URL(fileURLWithPath: remotePath), progress: progress)
    }

    public func downloadDirectory(remotePath: String, to localURL: URL,
                                  progress: (@Sendable (String, UInt64, UInt64?) -> Void)?)
        async throws {
        try copyTree(from: URL(fileURLWithPath: remotePath), to: localURL, progress: progress)
    }

    public func uploadDirectory(localURL: URL, to remotePath: String,
                                progress: (@Sendable (String, UInt64, UInt64?) -> Void)?)
        async throws {
        try copyTree(from: localURL, to: URL(fileURLWithPath: remotePath), progress: progress)
    }

    public func close() {}

    private func copy(from source: URL, to destination: URL,
                      progress: (@Sendable (UInt64, UInt64?) -> Void)?) throws {
        // Replacing rather than failing: the caller has already asked the user
        // about overwriting by the time it gets here.
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
        let size = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? UInt64)
            ?? nil
        progress?(size ?? 0, size)
    }

    private func copyTree(from source: URL, to destination: URL,
                          progress: (@Sendable (String, UInt64, UInt64?) -> Void)?) throws {
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
        progress?(source.lastPathComponent, 0, nil)
    }
}

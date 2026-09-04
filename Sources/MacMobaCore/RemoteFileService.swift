// What the file browser needs from a remote filesystem, independent of how it
// gets there.
//
// SFTP and FTP have almost nothing in common on the wire — one is a binary
// protocol multiplexed inside an SSH channel, the other is text over two
// sockets — but the file browser only ever asks the same ten questions. Naming
// them here means the whole panel (upload, download, drag and drop, rename,
// recursive delete, edit-locally) works over either without a second copy.

import Foundation

/// Every requirement is `async` on purpose: `FTPClient` is an actor (FTP is
/// strictly one command at a time, so its state has to be serialised), and an
/// actor can only satisfy requirements that its callers are able to await.
/// Conformers are not required to be `Sendable` — the browser holds one from
/// the main actor and never hands it to another.
public extension RemoteFileService {
    /// Total bytes of the files under `remotePath`, for sizing a folder
    /// transfer before it starts.
    ///
    /// A folder transfer otherwise begins with no idea how big it is, so its
    /// progress bar is indeterminate — it moves, but it never means anything.
    /// One walk of the tree buys a real one.
    ///
    /// Built on `list`, so every service gets it without implementing
    /// anything; there is nothing protocol-specific about adding up sizes.
    /// Symlinks are skipped because the copy skips them, and counting bytes
    /// nobody will transfer is worse than reporting no size at all.
    func totalSize(ofDirectory remotePath: String) async throws -> UInt64 {
        var total: UInt64 = 0
        for item in try await list(remotePath) {
            try Task.checkCancellation()
            if item.isDirectory {
                let child = remotePath.hasSuffix("/")
                    ? remotePath + item.name : remotePath + "/" + item.name
                total += try await totalSize(ofDirectory: child)
            } else if !item.isSymlink {
                total += item.size
            }
        }
        return total
    }
}

public protocol RemoteFileService: AnyObject {
    /// Resolve a path to its absolute form; "." means "where am I".
    func realpath(_ path: String) async throws -> String
    func list(_ path: String) async throws -> [SFTPItem]
    func mkdir(_ path: String) async throws
    func removeFile(_ path: String) async throws
    func removeDirectoryRecursively(_ path: String) async throws
    func rename(_ oldPath: String, to newPath: String) async throws

    func download(remotePath: String, to localURL: URL,
                  progress: (@Sendable (UInt64, UInt64?) -> Void)?) async throws
    func upload(localURL: URL, to remotePath: String,
                progress: (@Sendable (UInt64, UInt64?) -> Void)?) async throws
    /// Progress is (file name, bytes done for that file, that file's total).
    func downloadDirectory(remotePath: String, to localURL: URL,
                           progress: (@Sendable (String, UInt64, UInt64?) -> Void)?) async throws
    func uploadDirectory(localURL: URL, to remotePath: String,
                         progress: (@Sendable (String, UInt64, UInt64?) -> Void)?) async throws

    /// chmod. Not every protocol can — plain FTP has no portable equivalent —
    /// so the default reports that, and `supportsPermissions` lets the UI hide
    /// the control rather than offer something that always fails.
    func setPermissions(_ path: String, mode: UInt32) async throws
    var supportsPermissions: Bool { get }

    func close() async
}

public extension RemoteFileService {
    var supportsPermissions: Bool { false }
    func setPermissions(_ path: String, mode: UInt32) async throws {
        throw SFTPError.unsupported("changing permissions")
    }
}

extension SFTPClient: RemoteFileService {
    public var supportsPermissions: Bool { true }
}

extension FTPClient: RemoteFileService {}

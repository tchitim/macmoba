// File clipboard for RDP, using lazy promises.
//
// A remote copy only tells us names and sizes. Rather than pulling every byte
// the moment someone presses ⌃C on the server — which would stall on a large
// folder nobody intended to paste — the pasteboard gets NSFilePromiseProvider
// objects. Bytes are fetched when a destination actually asks for the file.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// One file the remote session is offering.
struct RDPRemoteFile {
    let index: UInt32
    let name: String
    let size: UInt64
}

/// Fetches remote file bytes in chunks. Owned by the RDP tab; the promise
/// providers hold it weakly through their delegate.
@MainActor
final class RDPFileTransfers {
    /// Requested per round trip. Large enough to keep the channel busy, small
    /// enough that a stalled transfer is noticed quickly.
    private static let chunkSize: UInt32 = 64 * 1024

    private var nextRequestId: UInt32 = 1
    private var waiting: [UInt32: CheckedContinuation<Data?, Never>] = [:]

    /// Whoever can actually talk to the session. Set by RDPTab.
    var requestRange: ((UInt32, UInt32, UInt64, UInt32) -> Bool)?

    /// Called from the connection thread when a chunk arrives.
    nonisolated func deliver(requestId: UInt32, data: Data?, failed: Bool) {
        Task { @MainActor in
            guard let continuation = self.waiting.removeValue(forKey: requestId) else { return }
            continuation.resume(returning: failed ? nil : data)
        }
    }

    /// Cancel everything still outstanding — used when the session drops, so
    /// no promise is left waiting forever.
    func cancelAll() {
        for (_, continuation) in waiting { continuation.resume(returning: nil) }
        waiting.removeAll()
    }

    private func fetchChunk(index: UInt32, offset: UInt64, length: UInt32) async -> Data? {
        let requestId = nextRequestId
        nextRequestId &+= 1
        guard requestRange?(requestId, index, offset, length) == true else { return nil }
        return await withCheckedContinuation { continuation in
            waiting[requestId] = continuation
        }
    }

    /// Stream one remote file to `url`. Written incrementally so a large file
    /// never has to be held in memory.
    func download(_ file: RDPRemoteFile, to url: URL) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }

        var offset: UInt64 = 0
        while offset < file.size {
            let remaining = file.size - offset
            let want = UInt32(min(UInt64(Self.chunkSize), remaining))
            guard let chunk = await fetchChunk(index: file.index, offset: offset,
                                               length: want), !chunk.isEmpty else {
                // A short or failed read mid-file means the transfer is broken;
                // surfacing it beats leaving a silently truncated file.
                throw CocoaError(.fileReadUnknown)
            }
            try handle.write(contentsOf: chunk)
            offset += UInt64(chunk.count)
        }
    }
}

/// Serves one promised file. AppKit asks for the bytes only when a destination
/// accepts the drop or paste.
final class RDPFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let file: RDPRemoteFile
    private weak var transfers: RDPFileTransfers?
    private let queue = OperationQueue()

    init(file: RDPRemoteFile, transfers: RDPFileTransfers) {
        self.file = file
        self.transfers = transfers
        super.init()
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             fileNameForType type: String) -> String {
        // Only the leaf name: the destination decides where it lands.
        (file.name as NSString).lastPathComponent
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let transfers else {
            completionHandler(CocoaError(.fileReadUnknown))
            return
        }
        Task { @MainActor in
            do {
                try await transfers.download(file, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

enum RDPFileClipboard {
    /// Files bigger than this are left as promises only. Otherwise copying a
    /// large folder in Explorer would pull every byte across whether or not
    /// you ever paste it.
    static let eagerSizeLimit: UInt64 = 200 * 1024 * 1024

    /// Put promises for the remote files on the pasteboard. Returns the
    /// pasteboard change count they were written at, so a later materialisation
    /// can tell whether the clipboard has moved on.
    @MainActor
    @discardableResult
    static func offerToPasteboard(_ files: [RDPRemoteFile],
                                  transfers: RDPFileTransfers) -> Int {
        guard !files.isEmpty else { return NSPasteboard.general.changeCount }
        let providers: [NSFilePromiseProvider] = files.map { file in
            let type = UTType(filenameExtension: (file.name as NSString).pathExtension)
                ?? .data
            return NSFilePromiseProvider(fileType: type.identifier,
                                         delegate: RDPFilePromiseDelegate(
                                            file: file, transfers: transfers))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(providers)
        return NSPasteboard.general.changeCount
    }

    /// A folder to stage this copy's files in, unique per copy so a second copy
    /// cannot overwrite files the first one is still handing out.
    static func makeStagingDirectory() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMoba-RDP-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    /// Replace the promises with real file URLs. Only does so when the
    /// pasteboard is still the one we wrote — if something else has been copied
    /// in the meantime, clobbering it would be worse than not pasting files.
    @MainActor
    static func replacePromises(withFilesAt urls: [URL], ifChangeCountIs expected: Int) -> Bool {
        guard !urls.isEmpty, NSPasteboard.general.changeCount == expected else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        return true
    }

    /// Absolute paths of files on the pasteboard, newline separated for the C
    /// layer. Empty when the pasteboard holds something other than files.
    static func localFilePaths(from board: NSPasteboard) -> String? {
        guard let urls = board.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true])
                as? [URL], !urls.isEmpty else { return nil }
        return urls.map(\.path).joined(separator: "\n")
    }
}

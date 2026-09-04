// SFTP v3 client (draft-ietf-secsh-filexfer-02) over a NIOSSH subsystem
// channel. NIOSSH has no built-in SFTP, so the packet layer is hand-rolled,
// same as OpenSSHKeyParser. One SFTPClient = its own SSH connection,
// mirroring the LocalForward model.

import Foundation
import NIOCore
import NIOSSH

public enum SFTPError: Error, CustomStringConvertible {
    case status(code: UInt32, message: String)
    case protocolError(String)
    case closed
    case localFile(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .status(let code, let message):
            let names: [UInt32: String] = [
                1: "EOF", 2: "no such file", 3: "permission denied",
                4: "failure", 5: "bad message", 8: "unsupported",
            ]
            let name = names[code] ?? "code \(code)"
            return message.isEmpty ? name : "\(name): \(message)"
        case .protocolError(let m): return "sftp protocol error: \(m)"
        case .closed: return "sftp channel closed"
        case .localFile(let m): return "local file error: \(m)"
        case .unsupported(let m): return "\(m) is not supported on this connection"
        }
    }
}

public struct SFTPAttributes: Sendable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var atime: UInt32?
    public var mtime: UInt32?
}

public struct SFTPItem: Identifiable, Sendable {
    public var name: String
    public var longname: String
    public var attributes: SFTPAttributes

    public var id: String { name }
    public var isDirectory: Bool { (attributes.permissions ?? 0) & 0o170000 == 0o040000 }
    public var isSymlink: Bool { (attributes.permissions ?? 0) & 0o170000 == 0o120000 }
    public var size: UInt64 { attributes.size ?? 0 }
    public var modified: Date? {
        attributes.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

// MARK: - Packet types

private enum PacketType {
    static let initialize: UInt8 = 1
    static let version: UInt8 = 2
    static let open: UInt8 = 3
    static let close: UInt8 = 4
    static let read: UInt8 = 5
    static let write: UInt8 = 6
    static let setstat: UInt8 = 9
    static let opendir: UInt8 = 11
    static let readdir: UInt8 = 12
    static let remove: UInt8 = 13
    static let mkdir: UInt8 = 14
    static let rmdir: UInt8 = 15
    static let realpath: UInt8 = 16
    static let stat: UInt8 = 17
    static let rename: UInt8 = 18
    static let status: UInt8 = 101
    static let handle: UInt8 = 102
    static let data: UInt8 = 103
    static let name: UInt8 = 104
    static let attrs: UInt8 = 105
}

private enum OpenFlags {
    static let read: UInt32 = 0x01
    static let write: UInt32 = 0x02
    static let creat: UInt32 = 0x08
    static let trunc: UInt32 = 0x10
}

enum SFTPResponse {
    case status(code: UInt32, message: String)
    case handle(Data)
    case fileData(Data)
    case name([SFTPItem])
    case attrs(SFTPAttributes)
}

// MARK: - Wire helpers

private extension ByteBuffer {
    mutating func writeSFTPString(_ s: String) {
        let bytes = Array(s.utf8)
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }

    mutating func writeSFTPData(_ d: Data) {
        writeInteger(UInt32(d.count))
        writeBytes(d)
    }

    mutating func readSFTPString() -> String? {
        guard let len: UInt32 = readInteger(),
              let bytes = readBytes(length: Int(len)) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readSFTPData() -> Data? {
        guard let len: UInt32 = readInteger(),
              let bytes = readBytes(length: Int(len)) else { return nil }
        return Data(bytes)
    }

    mutating func readSFTPAttributes() -> SFTPAttributes? {
        guard let flags: UInt32 = readInteger() else { return nil }
        var a = SFTPAttributes()
        if flags & 0x1 != 0 {
            guard let v: UInt64 = readInteger() else { return nil }
            a.size = v
        }
        if flags & 0x2 != 0 {
            guard let uid: UInt32 = readInteger(), let gid: UInt32 = readInteger() else { return nil }
            a.uid = uid
            a.gid = gid
        }
        if flags & 0x4 != 0 {
            guard let v: UInt32 = readInteger() else { return nil }
            a.permissions = v
        }
        if flags & 0x8 != 0 {
            guard let at: UInt32 = readInteger(), let mt: UInt32 = readInteger() else { return nil }
            a.atime = at
            a.mtime = mt
        }
        if flags & 0x8000_0000 != 0 {
            guard let count: UInt32 = readInteger() else { return nil }
            for _ in 0..<count {
                guard readSFTPData() != nil, readSFTPData() != nil else { return nil }
            }
        }
        return a
    }
}

// MARK: - Channel handler

final class SFTPPacketHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private var accumulator: ByteBuffer?
    private var pending: [UInt32: EventLoopPromise<SFTPResponse>] = [:]
    private var nextRequestID: UInt32 = 0
    private var context: ChannelHandlerContext?
    private var versionCompleted = false
    let versionPromise: EventLoopPromise<Void>

    init(versionPromise: EventLoopPromise<Void>) {
        self.versionPromise = versionPromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        accumulator = context.channel.allocator.buffer(capacity: 4096)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        failAll(SFTPError.closed)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(SFTPError.closed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error)
        context.close(promise: nil)
    }

    private func failAll(_ error: Error) {
        if !versionCompleted {
            versionCompleted = true
            versionPromise.fail(error)
        }
        let waiting = pending
        pending.removeAll()
        for (_, p) in waiting { p.fail(error) }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = channelData.data, channelData.type == .channel else { return }
        accumulator?.writeBuffer(&buf)
        parseFrames()
    }

    private func parseFrames() {
        while var acc = accumulator, acc.readableBytes >= 4 {
            guard let length = acc.getInteger(at: acc.readerIndex, as: UInt32.self),
                  acc.readableBytes >= 4 + Int(length) else { return }
            acc.moveReaderIndex(forwardBy: 4)
            guard var body = acc.readSlice(length: Int(length)) else { return }
            accumulator = acc
            dispatch(&body)
        }
    }

    private func dispatch(_ body: inout ByteBuffer) {
        guard let type: UInt8 = body.readInteger() else { return }
        if type == PacketType.version {
            if !versionCompleted {
                versionCompleted = true
                versionPromise.succeed(())
            }
            return
        }
        guard let requestID: UInt32 = body.readInteger(),
              let promise = pending.removeValue(forKey: requestID) else { return }

        switch type {
        case PacketType.status:
            guard let code: UInt32 = body.readInteger() else {
                return promise.fail(SFTPError.protocolError("truncated STATUS"))
            }
            let message = body.readSFTPString() ?? ""
            promise.succeed(.status(code: code, message: message))
        case PacketType.handle:
            guard let handle = body.readSFTPData() else {
                return promise.fail(SFTPError.protocolError("truncated HANDLE"))
            }
            promise.succeed(.handle(handle))
        case PacketType.data:
            guard let data = body.readSFTPData() else {
                return promise.fail(SFTPError.protocolError("truncated DATA"))
            }
            promise.succeed(.fileData(data))
        case PacketType.name:
            guard let count: UInt32 = body.readInteger() else {
                return promise.fail(SFTPError.protocolError("truncated NAME"))
            }
            var items: [SFTPItem] = []
            items.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let name = body.readSFTPString(),
                      let longname = body.readSFTPString(),
                      let attrs = body.readSFTPAttributes() else {
                    return promise.fail(SFTPError.protocolError("truncated NAME entry"))
                }
                items.append(SFTPItem(name: name, longname: longname, attributes: attrs))
            }
            promise.succeed(.name(items))
        case PacketType.attrs:
            guard let attrs = body.readSFTPAttributes() else {
                return promise.fail(SFTPError.protocolError("truncated ATTRS"))
            }
            promise.succeed(.attrs(attrs))
        default:
            promise.fail(SFTPError.protocolError("unexpected packet type \(type)"))
        }
    }

    /// Must be called on the channel's event loop.
    func sendRequest(type: UInt8, body: ByteBuffer) -> EventLoopFuture<SFTPResponse> {
        guard let context else {
            return versionPromise.futureResult.eventLoop.makeFailedFuture(SFTPError.closed)
        }
        nextRequestID &+= 1
        let requestID = nextRequestID
        let promise = context.eventLoop.makePromise(of: SFTPResponse.self)
        pending[requestID] = promise

        var frame = context.channel.allocator.buffer(capacity: body.readableBytes + 9)
        frame.writeInteger(UInt32(1 + 4 + body.readableBytes))
        frame.writeInteger(type)
        frame.writeInteger(requestID)
        var payload = body
        frame.writeBuffer(&payload)
        // context.write bypasses our own write() transform, so wrap here.
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(frame))), promise: nil)
        return promise.futureResult
    }

    /// Must be called on the channel's event loop.
    func sendInit() {
        guard let context else { return }
        var frame = context.channel.allocator.buffer(capacity: 9)
        frame.writeInteger(UInt32(5))
        frame.writeInteger(PacketType.initialize)
        frame.writeInteger(UInt32(3)) // protocol version
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(frame))), promise: nil)
    }
}

// MARK: - Public client

public final class SFTPClient {
    private let parentChannel: Channel
    private let channel: Channel
    private let handler: SFTPPacketHandler

    /// Chunk size for READ/WRITE. 32 KB is the universally safe SFTP maximum.
    private static let chunkSize = 32 * 1024
    /// Reads kept in flight at once, so a transfer is not one round trip per
    /// chunk. 16 x 32 KB is half a megabyte outstanding — enough to fill a
    /// LAN or VPN link without asking a server for an unreasonable backlog.
    private static let readWindow = 16

    private init(parent: Channel, channel: Channel, handler: SFTPPacketHandler) {
        self.parentChannel = parent
        self.channel = channel
        self.handler = handler
    }

    /// Open a dedicated SSH connection and start the sftp subsystem on it.
    ///
    /// - Parameter jump: the bastion to reach `config` through, exactly as the
    ///   terminal does. Without this the file browser dialled the target
    ///   directly while the terminal beside it went through the jump host —
    ///   which on a network where only the bastion is reachable means the
    ///   browser simply hangs on "Connecting…".
    public static func connect(
        config: SessionConfig,
        via jumps: [SessionConfig] = [],
        hostKeys: HostKeyVerification? = nil
    ) async throws -> SFTPClient {
        // Reach the target through however many bastions the chain describes.
        // Closing the returned parent tears the whole chain down (see
        // connectParentChain), so there is no bastion to track separately.
        let parent = try await SSHConnection.connectParentChain(
            hops: jumps, target: config, hostKeys: hostKeys)
        do {
            let versionPromise = parent.eventLoop.makePromise(of: Void.self)
            let handler = SFTPPacketHandler(versionPromise: versionPromise)
            let channel = try await SSHConnection.openSessionChannel(
                parent: parent, handler: handler,
                timeoutSeconds: hostKeys == nil ? 8 : 180)
            let subsystem = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
            try await channel.triggerUserOutboundEvent(subsystem).get()
            channel.eventLoop.execute { handler.sendInit() }
            try await SSHConnection.withTimeout(versionPromise.futureResult, on: channel.eventLoop,
                                               seconds: 8, what: "sftp handshake")
            return SFTPClient(parent: parent, channel: channel, handler: handler)
        } catch {
            parent.close(promise: nil)
            throw error
        }
    }

    public func close() {
        channel.close(promise: nil)
        // Closing the parent cascades to every bastion in the chain.
        parentChannel.close(promise: nil)
    }

    // MARK: - Requests

    private func request(_ type: UInt8, _ build: (inout ByteBuffer) -> Void) async throws -> SFTPResponse {
        var body = channel.allocator.buffer(capacity: 256)
        build(&body)
        let handler = self.handler
        return try await channel.eventLoop.flatSubmit {
            handler.sendRequest(type: type, body: body)
        }.get()
    }

    /// Hand a read to the packet layer and get its future back WITHOUT
    /// awaiting it, so several can be outstanding at once.
    ///
    /// `request` awaits its own answer, which is right for everything that
    /// asks one question; a pipelined download needs the future itself.
    private func enqueueRead(handle: Data, offset: UInt64) async throws
        -> EventLoopFuture<SFTPResponse> {
        var body = channel.allocator.buffer(capacity: 256)
        body.writeSFTPData(handle)
        body.writeInteger(offset)
        body.writeInteger(UInt32(Self.chunkSize))
        let handler = self.handler
        return try await channel.eventLoop.submit {
            handler.sendRequest(type: PacketType.read, body: body)
        }.get()
    }

    /// For requests where the only success answer is STATUS(OK).
    private func expectOK(_ type: UInt8, _ build: (inout ByteBuffer) -> Void) async throws {
        let response = try await request(type, build)
        guard case .status(let code, let message) = response else {
            throw SFTPError.protocolError("expected STATUS")
        }
        guard code == 0 else { throw SFTPError.status(code: code, message: message) }
    }

    public func realpath(_ path: String) async throws -> String {
        let response = try await request(PacketType.realpath) { $0.writeSFTPString(path) }
        guard case .name(let items) = response, let first = items.first else {
            if case .status(let code, let message) = response {
                throw SFTPError.status(code: code, message: message)
            }
            throw SFTPError.protocolError("REALPATH: expected NAME")
        }
        return first.name
    }

    public func stat(_ path: String) async throws -> SFTPAttributes {
        let response = try await request(PacketType.stat) { $0.writeSFTPString(path) }
        switch response {
        case .attrs(let a): return a
        case .status(let code, let message): throw SFTPError.status(code: code, message: message)
        default: throw SFTPError.protocolError("STAT: expected ATTRS")
        }
    }

    public func list(_ path: String) async throws -> [SFTPItem] {
        let handle = try await openDir(path)
        defer { Task { try? await self.closeHandle(handle) } }
        var items: [SFTPItem] = []
        while true {
            let response = try await request(PacketType.readdir) { $0.writeSFTPData(handle) }
            switch response {
            case .name(let batch):
                items.append(contentsOf: batch)
            case .status(let code, let message):
                if code == 1 { // EOF
                    return items.filter { $0.name != "." && $0.name != ".." }
                }
                throw SFTPError.status(code: code, message: message)
            default:
                throw SFTPError.protocolError("READDIR: expected NAME or STATUS")
            }
        }
    }

    public func mkdir(_ path: String) async throws {
        try await expectOK(PacketType.mkdir) {
            $0.writeSFTPString(path)
            $0.writeInteger(UInt32(0)) // empty ATTRS
        }
    }

    public func removeFile(_ path: String) async throws {
        try await expectOK(PacketType.remove) { $0.writeSFTPString(path) }
    }

    public func removeDirectory(_ path: String) async throws {
        try await expectOK(PacketType.rmdir) { $0.writeSFTPString(path) }
    }

    /// Delete a directory tree. SFTP's RMDIR only removes empty directories,
    /// so children go first. Symlinks are removed as entries (never followed —
    /// list() reports them via lstat, so isDirectory is false for dir links).
    public func removeDirectoryRecursively(_ path: String) async throws {
        let items = try await list(path)
        for item in items {
            try Task.checkCancellation()
            let child = Self.join(path, item.name)
            if item.isDirectory {
                try await removeDirectoryRecursively(child)
            } else {
                try await removeFile(child)
            }
        }
        try await removeDirectory(path)
    }

    public func rename(_ oldPath: String, to newPath: String) async throws {
        try await expectOK(PacketType.rename) {
            $0.writeSFTPString(oldPath)
            $0.writeSFTPString(newPath)
        }
    }

    /// chmod. Only the permission/setuid/setgid/sticky bits are sent (masked to
    /// 0o7777); the file-type bits are the server's to keep. The ATTRS flags
    /// field carries a single flag — SSH_FILEXFER_ATTR_PERMISSIONS (0x4).
    public func setPermissions(_ path: String, mode: UInt32) async throws {
        try await expectOK(PacketType.setstat) {
            $0.writeSFTPString(path)
            $0.writeInteger(UInt32(0x0000_0004))          // ATTR_PERMISSIONS
            $0.writeInteger(mode & FileMode.permissionMask)
        }
    }

    // MARK: - File transfer

    public func download(
        remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        let total = try? await stat(remotePath).size
        let handle = try await openFile(remotePath, flags: OpenFlags.read)
        defer { Task { try? await self.closeHandle(handle) } }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: localURL.path) else {
            throw SFTPError.localFile("cannot write \(localURL.path)")
        }
        defer { try? file.close() }

        // Reads are pipelined: a window of requests is in flight at once and
        // the replies are written in order.
        //
        // One 32 KB read at a time meant a round trip per chunk — 6,800 of
        // them for a 214 MB file, so even a 5 ms link spent half a minute
        // doing nothing but waiting, and the panel looked hung. The packet
        // layer already multiplexes on request id; only this loop was serial.
        var offset: UInt64 = 0
        var reachedEnd = false
        while !reachedEnd {
            try Task.checkCancellation()

            // Issue the window, then take the answers in order. Requests go
            // out before any is awaited, which is the whole point.
            var futures: [(offset: UInt64, future: EventLoopFuture<SFTPResponse>)] = []
            var planned = offset
            for _ in 0..<Self.readWindow {
                if let total, planned >= total { break }
                let at = planned
                futures.append((at, try await enqueueRead(handle: handle, offset: at)))
                planned += UInt64(Self.chunkSize)
            }
            if futures.isEmpty { break }

            for (at, future) in futures {
                let response = try await future.get()
                switch response {
                case .fileData(let data):
                    // Written at the offset it was asked for, not wherever the
                    // handle happens to sit: a short read earlier in the window
                    // would otherwise silently shift everything after it.
                    try file.seek(toOffset: at)
                    try file.write(contentsOf: data)
                    let end = at + UInt64(data.count)
                    if end > offset { offset = end }
                    progress?(offset, total ?? nil)
                    // A server may answer with less than was asked for. The
                    // gap is picked up by the next window, which restarts from
                    // the highest byte actually written.
                    if data.count < Self.chunkSize {
                        reachedEnd = total.map { offset >= $0 } ?? false
                        if !reachedEnd { planned = offset }
                    }
                case .status(let code, let message):
                    guard code == 1 else {
                        throw SFTPError.status(code: code, message: message)
                    }
                    reachedEnd = true      // EOF
                default:
                    throw SFTPError.protocolError("READ: expected DATA or STATUS")
                }
                if reachedEnd { break }
            }
            if let total, offset >= total { reachedEnd = true }
        }
        try file.truncate(atOffset: offset)
    }

    public func upload(
        localURL: URL,
        to remotePath: String,
        progress: (@Sendable (UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        guard let file = FileHandle(forReadingAtPath: localURL.path) else {
            throw SFTPError.localFile("cannot read \(localURL.path)")
        }
        defer { try? file.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? nil

        let handle = try await openFile(
            remotePath,
            flags: OpenFlags.write | OpenFlags.creat | OpenFlags.trunc
        )
        defer { Task { try? await self.closeHandle(handle) } }

        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: Self.chunkSize) ?? Data()
            if chunk.isEmpty { return }
            try await expectOK(PacketType.write) {
                $0.writeSFTPData(handle)
                $0.writeInteger(offset)
                $0.writeSFTPData(chunk)
            }
            offset += UInt64(chunk.count)
            progress?(offset, total)
        }
    }

    // MARK: - Recursive directory transfer

    /// Download a whole directory tree. `progress` reports (current file name,
    /// bytes done for that file, file total). Symlinks are skipped.
    public func downloadDirectory(
        remotePath: String,
        to localURL: URL,
        progress: (@Sendable (String, UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        let items = try await list(remotePath)
        for item in items {
            try Task.checkCancellation()
            let childRemote = Self.join(remotePath, item.name)
            let childLocal = localURL.appendingPathComponent(item.name)
            if item.isDirectory {
                try await downloadDirectory(remotePath: childRemote, to: childLocal, progress: progress)
            } else if !item.isSymlink {
                let name = item.name
                try await download(remotePath: childRemote, to: childLocal) { done, total in
                    progress?(name, done, total)
                }
            }
        }
    }

    /// Upload a whole local directory tree. Creates the remote root if missing.
    public func uploadDirectory(
        localURL: URL,
        to remotePath: String,
        progress: (@Sendable (String, UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        if (try? await stat(remotePath)) == nil {
            try await mkdir(remotePath)
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: localURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in entries {
            try Task.checkCancellation()
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            let childRemote = Self.join(remotePath, entry.lastPathComponent)
            if values.isDirectory == true {
                try await uploadDirectory(localURL: entry, to: childRemote, progress: progress)
            } else {
                let name = entry.lastPathComponent
                try await upload(localURL: entry, to: childRemote) { done, total in
                    progress?(name, done, total)
                }
            }
        }
    }

    static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    // MARK: - Handles

    private func openFile(_ path: String, flags: UInt32) async throws -> Data {
        let response = try await request(PacketType.open) {
            $0.writeSFTPString(path)
            $0.writeInteger(flags)
            $0.writeInteger(UInt32(0)) // empty ATTRS
        }
        switch response {
        case .handle(let h): return h
        case .status(let code, let message): throw SFTPError.status(code: code, message: message)
        default: throw SFTPError.protocolError("OPEN: expected HANDLE")
        }
    }

    private func openDir(_ path: String) async throws -> Data {
        let response = try await request(PacketType.opendir) { $0.writeSFTPString(path) }
        switch response {
        case .handle(let h): return h
        case .status(let code, let message): throw SFTPError.status(code: code, message: message)
        default: throw SFTPError.protocolError("OPENDIR: expected HANDLE")
        }
    }

    private func closeHandle(_ handle: Data) async throws {
        try await expectOK(PacketType.close) { $0.writeSFTPData(handle) }
    }
}

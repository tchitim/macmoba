// The control socket — cmux's scriptability, MacMoba edition. A `macmoba` CLI
// (or any script, or an agent on the other end of an SSH session back into
// this Mac) can list tabs, type into them, read their screens and raise
// notifications, over a Unix socket only this user can reach.
//
// Wire format: one JSON object per line, both directions.
//   → {"token":"…","cmd":"list-tabs","args":{…}}
//   ← {"ok":true,"data":…}   |   {"ok":false,"error":"…"}
//
// Security: the socket lives in the app's data directory (0700) with a 0600
// token file beside it, regenerated each launch. Every request must carry the
// token — a different local user cannot read it, and a stale CLI fails closed.

import Foundation
import NIOCore
import NIOPosix

// MARK: - Protocol types

public struct ControlRequest: Codable, Sendable {
    public var token: String
    public var cmd: String
    /// Free-form string arguments; commands validate what they need.
    public var args: [String: String]

    public init(token: String, cmd: String, args: [String: String] = [:]) {
        self.token = token
        self.cmd = cmd
        self.args = args
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    /// Arbitrary JSON payload, already encoded — keeps this type simple while
    /// letting commands return arrays or objects.
    public var data: String?
    public var error: String?

    public static func success(json: String? = nil) -> ControlResponse {
        ControlResponse(ok: true, data: json, error: nil)
    }
    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, data: nil, error: message)
    }
}

public enum ControlProtocol {
    public static func decodeRequest(_ line: String) -> ControlRequest? {
        try? JSONDecoder().decode(ControlRequest.self, from: Data(line.utf8))
    }

    public static func encode<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Server

public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let group: EventLoopGroup
    private let channel: Channel
    public let socketPath: String

    private init(group: EventLoopGroup, channel: Channel, socketPath: String) {
        self.group = group
        self.channel = channel
        self.socketPath = socketPath
    }

    /// Listen on `socketPath`; requests whose token differs from `token` are
    /// refused before the handler ever sees them.
    public static func start(
        socketPath: String,
        token: String,
        handler: @escaping Handler
    ) async throws -> ControlServer {
        // A previous run's socket file blocks bind — it is ours to remove.
        try? FileManager.default.removeItem(atPath: socketPath)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(
                        ControlConnectionHandler(token: token, handler: handler))
                }
                .bind(unixDomainSocketPath: socketPath)
                .get()
            // Belt and braces on top of the 0700 directory.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: socketPath)
            return ControlServer(group: group, channel: channel, socketPath: socketPath)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() {
        channel.close(promise: nil)
        try? FileManager.default.removeItem(atPath: socketPath)
        let group = self.group
        Task { try? await group.shutdownGracefully() }
    }
}

/// One client connection: buffers bytes into lines, answers each line.
private final class ControlConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let token: String
    private let handler: ControlServer.Handler
    private var buffer = ""

    init(token: String, handler: @escaping ControlServer.Handler) {
        self.token = token
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        guard let chunk = inbound.readString(length: inbound.readableBytes) else { return }
        buffer += chunk
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            respond(to: line, context: context)
        }
    }

    private func respond(to line: String, context: ChannelHandlerContext) {
        let channel = context.channel
        guard let request = ControlProtocol.decodeRequest(line) else {
            write(ControlResponse.failure("malformed request (want one JSON object per line)"),
                  to: channel)
            return
        }
        guard request.token == token else {
            write(ControlResponse.failure("bad token"), to: channel)
            return
        }
        let handler = self.handler
        Task {
            let response = await handler(request)
            self.write(response, to: channel)
        }
    }

    private func write(_ response: ControlResponse, to channel: Channel) {
        let line = ControlProtocol.encode(response) + "\n"
        let eventLoop = channel.eventLoop
        eventLoop.execute {
            var out = channel.allocator.buffer(capacity: line.utf8.count)
            out.writeString(line)
            channel.writeAndFlush(out, promise: nil)
        }
    }
}

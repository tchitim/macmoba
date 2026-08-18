// Rlogin transport: a plain TCP socket that speaks the tiny rlogin handshake,
// then streams bytes. Mirrors TelnetConnection's shape (connect / write /
// resize / close with onData + onExit) so a terminal pane treats it the same.
// The protocol formatting is in RloginProtocol; this is the socket + threading.

import Foundation
import NIOCore
import NIOPosix

public final class RloginConnection: @unchecked Sendable {
    private let channel: Channel
    private let group: EventLoopGroup

    private init(channel: Channel, group: EventLoopGroup) {
        self.channel = channel
        self.group = group
    }

    /// Opens the connection and sends the handshake. `localUser` defaults to the
    /// Mac login; `remoteUser` is the account to log in as on the far end.
    public static func connect(
        config: SessionConfig,
        localUser: String,
        cols: Int = 80,
        rows: Int = 24,
        onData: @escaping (Data) -> Void,
        onExit: @escaping (String) -> Void
    ) async throws -> RloginConnection {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handshake = RloginProtocol.connectString(
            localUser: localUser.isEmpty ? "user" : localUser,
            remoteUser: config.username.isEmpty ? localUser : config.username)
        let handler = RloginHandler(handshake: handshake, cols: cols, rows: rows,
                                    onData: onData, onExit: onExit)
        do {
            let channel = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .channelInitializer { $0.pipeline.addHandler(handler) }
                .connect(host: config.host, port: config.port)
                .get()
            return RloginConnection(channel: channel, group: group)
        } catch {
            try? await group.shutdownGracefully()
            throw TelnetError.connectionFailed(
                "Could not reach \(config.host):\(config.port) — \(error.localizedDescription)")
        }
    }

    public func write(_ data: Data) {
        let bytes = Array(data)
        channel.eventLoop.execute { [channel] in
            var out = channel.allocator.buffer(capacity: bytes.count)
            out.writeBytes(bytes)
            channel.writeAndFlush(out, promise: nil)
        }
    }

    public func resize(cols: Int, rows: Int) {
        let message = RloginProtocol.windowSizeMessage(cols: cols, rows: rows)
        channel.eventLoop.execute { [channel] in
            var out = channel.allocator.buffer(capacity: message.count)
            out.writeBytes(message)
            channel.writeAndFlush(out, promise: nil)
        }
    }

    public func close() {
        channel.close(promise: nil)
        let group = self.group
        Task { try? await group.shutdownGracefully() }
    }
}

extension RloginConnection: TerminalTransport {}

/// Sends the handshake once connected, swallows the one-byte ack, then passes
/// everything through. Runs entirely on the channel's event loop.
private final class RloginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let handshake: [UInt8]
    private let cols: Int
    private let rows: Int
    private let onData: (Data) -> Void
    private let onExit: (String) -> Void
    private var ackSeen = false
    private var reportedExit = false

    init(handshake: [UInt8], cols: Int, rows: Int,
         onData: @escaping (Data) -> Void, onExit: @escaping (String) -> Void) {
        self.handshake = handshake
        self.cols = cols
        self.rows = rows
        self.onData = onData
        self.onExit = onExit
    }

    func channelActive(context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: handshake.count)
        out.writeBytes(handshake)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        // Tell the server our window size straight after the handshake.
        let ws = RloginProtocol.windowSizeMessage(cols: cols, rows: rows)
        var wsBuf = context.channel.allocator.buffer(capacity: ws.count)
        wsBuf.writeBytes(ws)
        context.writeAndFlush(wrapOutboundOut(wsBuf), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        if ackSeen {
            onData(Data(bytes))
            return
        }
        // First packet: the leading byte is the status.
        ackSeen = true
        switch RloginProtocol.interpretReply(bytes) {
        case .accepted(let payload):
            if !payload.isEmpty { onData(Data(payload)) }
        case .rejected(let message):
            reportExit(message)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        reportExit("Connection closed by the remote host.")
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        reportExit(error.localizedDescription)
        context.close(promise: nil)
    }

    private func reportExit(_ reason: String) {
        guard !reportedExit else { return }
        reportedExit = true
        onExit(reason)
    }
}

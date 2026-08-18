// Telnet transport: a plain TCP socket with RFC 854 negotiation on top.
//
// Deliberately mirrors SSHConnection's shape (connect / write / resize / close
// with onData + onExit callbacks) so a terminal pane does not care which it
// has. All the protocol logic lives in TelnetNegotiator; this file is the
// socket and the threading.

import Foundation
import NIOCore
import NIOPosix

public enum TelnetError: Error, LocalizedError {
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail): return detail
        }
    }
}

public final class TelnetConnection: @unchecked Sendable {
    private let channel: Channel
    private let group: EventLoopGroup
    private let handler: TelnetHandler

    private init(channel: Channel, group: EventLoopGroup, handler: TelnetHandler) {
        self.channel = channel
        self.group = group
        self.handler = handler
    }

    /// Opens the connection and starts the terminal session. There is no
    /// authentication step: Telnet logs in through the terminal itself, which
    /// is exactly why the traffic is worth warning about.
    public static func connect(
        config: SessionConfig,
        cols: Int = 80,
        rows: Int = 24,
        onData: @escaping (Data) -> Void,
        onExit: @escaping (String) -> Void
    ) async throws -> TelnetConnection {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handler = TelnetHandler(cols: cols, rows: rows, onData: onData, onExit: onExit)

        do {
            let channel = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handler)
                }
                .connect(host: config.host, port: config.port)
                .get()
            return TelnetConnection(channel: channel, group: group, handler: handler)
        } catch {
            // The group owns a thread; leaving it running after a failed
            // connect leaks one per attempt.
            try? await group.shutdownGracefully()
            throw TelnetError.connectionFailed(
                "Could not reach \(config.host):\(config.port) — \(error.localizedDescription)")
        }
    }

    public func write(_ data: Data) {
        handler.send(Array(data), on: channel)
    }

    /// Telnet has no resize message of its own; the size goes out as a NAWS
    /// subnegotiation, and only if the server asked for that option.
    public func resize(cols: Int, rows: Int) {
        handler.resize(cols: cols, rows: rows, on: channel)
    }

    public func close() {
        channel.close(promise: nil)
        let group = self.group
        Task { try? await group.shutdownGracefully() }
    }
}

extension TelnetConnection: TerminalTransport {}

/// Owns the negotiator. Every method runs on the channel's event loop, which is
/// what makes the mutable negotiator state safe without a lock.
private final class TelnetHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var negotiator: TelnetNegotiator
    private let onData: (Data) -> Void
    private let onExit: (String) -> Void
    private var reportedExit = false

    init(cols: Int, rows: Int, onData: @escaping (Data) -> Void,
         onExit: @escaping (String) -> Void) {
        self.negotiator = TelnetNegotiator(cols: cols, rows: rows)
        self.onData = onData
        self.onExit = onExit
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        let output = negotiator.receive(bytes)
        if !output.reply.isEmpty {
            var out = context.channel.allocator.buffer(capacity: output.reply.count)
            out.writeBytes(output.reply)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
        if !output.terminalData.isEmpty {
            onData(Data(output.terminalData))
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

    func send(_ bytes: [UInt8], on channel: Channel) {
        let encoded = TelnetNegotiator.encodeInput(bytes)
        var out = channel.allocator.buffer(capacity: encoded.count)
        out.writeBytes(encoded)
        channel.writeAndFlush(out, promise: nil)
    }

    func resize(cols: Int, rows: Int, on channel: Channel) {
        // Touches the negotiator, so it has to happen on the event loop.
        channel.eventLoop.execute { [self] in
            let payload = negotiator.windowSizeChanged(cols: cols, rows: rows)
            guard !payload.isEmpty else { return }
            var out = channel.allocator.buffer(capacity: payload.count)
            out.writeBytes(payload)
            channel.writeAndFlush(out, promise: nil)
        }
    }
}

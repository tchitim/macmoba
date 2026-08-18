// Dynamic forwarding (ssh -D): a local SOCKS5 proxy whose CONNECT requests
// each become a direct-tcpip channel on the SSH connection.
//
// SOCKS5 (RFC 1928) is implemented here rather than pulled in as a dependency;
// only the no-auth CONNECT path is needed, but all three address types are
// supported because browsers use domain names and IPv6 in practice.

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum Socks {
    static let version: UInt8 = 5
    static let noAuth: UInt8 = 0
    static let cmdConnect: UInt8 = 1

    enum Reply: UInt8 {
        case success = 0
        case generalFailure = 1
        case commandNotSupported = 7
        case addressTypeNotSupported = 8
    }

    enum AddressType: UInt8 {
        case ipv4 = 1
        case domain = 3
        case ipv6 = 4
    }
}

/// Parses the SOCKS5 handshake, then hands the target over to `onConnect`.
final class SocksHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage {
        case greeting
        case request
        case streaming
    }

    private var stage: Stage = .greeting
    private var buffer: ByteBuffer?
    private let onConnect: (Channel, String, Int) -> Void

    init(onConnect: @escaping (Channel, String, Int) -> Void) {
        self.onConnect = onConnect
    }

    func handlerAdded(context: ChannelHandlerContext) {
        buffer = context.channel.allocator.buffer(capacity: 64)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard stage != .streaming else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer?.writeBuffer(&incoming)
        process(context: context)
    }

    private func process(context: ChannelHandlerContext) {
        while true {
            guard var buf = buffer else { return }
            switch stage {
            case .greeting:
                // VER | NMETHODS | METHODS...
                guard buf.readableBytes >= 2,
                      let version: UInt8 = buf.getInteger(at: buf.readerIndex),
                      let count: UInt8 = buf.getInteger(at: buf.readerIndex + 1) else { return }
                guard version == Socks.version else {
                    context.close(promise: nil)
                    return
                }
                let total = 2 + Int(count)
                guard buf.readableBytes >= total else { return }
                buf.moveReaderIndex(forwardBy: total)
                buffer = buf
                // We only offer "no authentication".
                var reply = context.channel.allocator.buffer(capacity: 2)
                reply.writeInteger(Socks.version)
                reply.writeInteger(Socks.noAuth)
                context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
                stage = .request

            case .request:
                // VER | CMD | RSV | ATYP | ADDR | PORT
                guard buf.readableBytes >= 4,
                      let version: UInt8 = buf.getInteger(at: buf.readerIndex),
                      let command: UInt8 = buf.getInteger(at: buf.readerIndex + 1),
                      let rawType: UInt8 = buf.getInteger(at: buf.readerIndex + 3) else { return }
                guard version == Socks.version else {
                    context.close(promise: nil)
                    return
                }
                guard command == Socks.cmdConnect else {
                    respond(context: context, reply: .commandNotSupported)
                    context.close(promise: nil)
                    return
                }
                guard let type = Socks.AddressType(rawValue: rawType) else {
                    respond(context: context, reply: .addressTypeNotSupported)
                    context.close(promise: nil)
                    return
                }

                // Length of the address field varies by type.
                let addressLength: Int
                switch type {
                case .ipv4: addressLength = 4
                case .ipv6: addressLength = 16
                case .domain:
                    guard buf.readableBytes >= 5,
                          let len: UInt8 = buf.getInteger(at: buf.readerIndex + 4) else { return }
                    addressLength = 1 + Int(len)
                }
                let total = 4 + addressLength + 2
                guard buf.readableBytes >= total else { return }

                buf.moveReaderIndex(forwardBy: 4)
                let host: String
                switch type {
                case .ipv4:
                    let bytes = buf.readBytes(length: 4) ?? []
                    host = bytes.map(String.init).joined(separator: ".")
                case .ipv6:
                    let bytes = buf.readBytes(length: 16) ?? []
                    host = stride(from: 0, to: 16, by: 2)
                        .map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }
                        .joined(separator: ":")
                case .domain:
                    let len = Int(buf.readInteger(as: UInt8.self) ?? 0)
                    let bytes = buf.readBytes(length: len) ?? []
                    host = String(decoding: bytes, as: UTF8.self)
                }
                let port = Int(buf.readInteger(as: UInt16.self) ?? 0)
                buffer = buf
                stage = .streaming
                onConnect(context.channel, host, port)
            case .streaming:
                return
            }
        }
    }

    /// Success is answered with a zeroed bind address: clients ignore it, and
    /// it avoids leaking the SSH server's addressing.
    func respond(context: ChannelHandlerContext, reply: Socks.Reply) {
        var buf = context.channel.allocator.buffer(capacity: 10)
        buf.writeInteger(Socks.version)
        buf.writeInteger(reply.rawValue)
        buf.writeInteger(UInt8(0))
        buf.writeInteger(Socks.AddressType.ipv4.rawValue)
        buf.writeInteger(UInt32(0))
        buf.writeInteger(UInt16(0))
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }
}

public final class DynamicForward {
    public let config: TunnelConfig
    private let parentChannel: Channel
    private let serverChannel: Channel

    private init(config: TunnelConfig, parent: Channel, server: Channel) {
        self.config = config
        self.parentChannel = parent
        self.serverChannel = server
    }

    public var localPort: Int { serverChannel.localAddress?.port ?? config.bindPort }

    public static func start(
        config: TunnelConfig,
        session: SessionConfig,
        via hops: [SessionConfig] = [],
        hostKeys: HostKeyVerification? = nil
    ) async throws -> DynamicForward {
        precondition(config.type == "dynamic", "DynamicForward requires type == dynamic")
        // Reach the gateway through its own bastion chain, if it has one.
        let parent = try await SSHConnection.connectParentChain(
            hops: hops, target: session, hostKeys: hostKeys)
        let ssh = try await parent.pipeline.handler(type: NIOSSHHandler.self).get()

        let bootstrap = ServerBootstrap(group: SSHRuntime.group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { local in
                let handshake = SocksHandshakeHandler { channel, host, port in
                    // One direct-tcpip channel per SOCKS CONNECT.
                    let (localGlue, sshGlue) = GlueHandler.matchedPair()
                    let promise = parent.eventLoop.makePromise(of: Channel.self)
                    let type = SSHChannelType.directTCPIP(.init(
                        targetHost: host,
                        targetPort: port,
                        originatorAddress: channel.remoteAddress
                            ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                    ))
                    ssh.createChannel(promise, channelType: type) { child, _ in
                        child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                            child.pipeline.addHandlers([SSHDataCodec(), sshGlue])
                        }
                    }
                    promise.futureResult.whenComplete { result in
                        switch result {
                        case .success:
                            // Tell the client we're connected, then splice the
                            // two sides together and step out of the way.
                            channel.pipeline.handler(type: SocksHandshakeHandler.self)
                                .whenSuccess { handler in
                                    channel.pipeline.context(handler: handler).whenSuccess { ctx in
                                        handler.respond(context: ctx, reply: .success)
                                        _ = channel.pipeline.addHandler(localGlue)
                                            .flatMap { channel.pipeline.removeHandler(handler) }
                                    }
                                }
                        case .failure:
                            channel.pipeline.handler(type: SocksHandshakeHandler.self)
                                .whenSuccess { handler in
                                    channel.pipeline.context(handler: handler).whenSuccess { ctx in
                                        handler.respond(context: ctx, reply: .generalFailure)
                                        channel.close(promise: nil)
                                    }
                                }
                        }
                    }
                }
                // The browser's side needs half-closure too, so that its own
                // "no more requests" is passed on as EOF rather than tearing
                // the whole connection down mid-response.
                return local.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .flatMap { local.pipeline.addHandler(handshake) }
            }
        do {
            let server = try await bootstrap.bind(host: config.bindHost, port: config.bindPort).get()
            return DynamicForward(config: config, parent: parent, server: server)
        } catch {
            parent.close(promise: nil)
            throw error
        }
    }

    public func stop() {
        serverChannel.close(promise: nil)
        parentChannel.close(promise: nil)
    }
}

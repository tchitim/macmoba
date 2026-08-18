// SSH port forwarding.
// -L (LocalForward): listen locally, forward each connection through a
//   dedicated SSH connection as a direct-tcpip channel.
// -R (RemoteForward): ask the server to listen (tcpip-forward global request);
//   the server opens forwarded-tcpip channels back to us, which we glue to a
//   local TCP connection to the target.

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Converts SSHChannelData <-> ByteBuffer so both sides of the glue speak ByteBuffer.
final class SSHDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = channelData.data else { return }
        context.fireChannelRead(wrapInboundOut(buf))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: promise)
    }
}

/// Pairs two channels: everything read on one side is written to the other.
/// All channels run on the shared single-threaded loop, but writes are still
/// marshalled through the partner's event loop for safety.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pending: [ByteBuffer] = []
    private var partnerClosed = false
    private var partnerStoppedSending = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler()
        let b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        drainPending()
        if partnerClosed { context.close(promise: nil) }
        else if partnerStoppedSending { closeOutput(context) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        partner?.enqueue(buf)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.flushIfPossible()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerDidClose()
        context.fireChannelInactive()
    }

    /// Half-close is where the interesting failure was.
    ///
    /// Both sides run with `allowRemoteHalfClosure`, so when the far end stops
    /// sending, NIO reports `inputClosed` and does NOT fire `channelInactive`.
    /// Swallowing that event leaves the other side waiting for bytes that will
    /// never come: an HTTP response with no Content-Length — a streaming
    /// endpoint, `Connection: close`, or a server retiring an idle keep-alive
    /// connection — never finishes, because "the body ends here" IS the EOF.
    /// The browser then keeps handing requests to connections that are already
    /// dead, and the page crawls.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(ChannelEvent.inputClosed) = event as? ChannelEvent {
            partner?.partnerStoppedSendingData()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerDidClose()
        context.close(promise: nil)
    }

    private func enqueue(_ buf: ByteBuffer) {
        onOwnLoop { [self] in
            if let ctx = context {
                ctx.write(NIOAny(buf), promise: nil)
            } else {
                pending.append(buf)
            }
        }
    }

    private func flushIfPossible() {
        onOwnLoop { [self] in context?.flush() }
    }

    /// Pass the EOF on: stop writing to our side, but keep reading, because
    /// the other direction may still have data (a request still uploading
    /// while the response has finished).
    private func partnerStoppedSendingData() {
        onOwnLoop { [self] in
            partnerStoppedSending = true
            if let ctx = context { closeOutput(ctx) }
        }
    }

    private func closeOutput(_ ctx: ChannelHandlerContext) {
        ctx.flush()
        // Not every channel supports a write-side-only close; where it is not
        // available, closing outright still beats hanging forever.
        ctx.close(mode: .output).whenFailure { _ in ctx.close(promise: nil) }
    }

    private func partnerDidClose() {
        onOwnLoop { [self] in
            partnerClosed = true
            if let ctx = context {
                ctx.flush()
                ctx.close(promise: nil)
            }
        }
    }

    private func drainPending() {
        guard let ctx = context, !pending.isEmpty else { return }
        for buf in pending { ctx.write(NIOAny(buf), promise: nil) }
        pending.removeAll()
        ctx.flush()
    }

    private func onOwnLoop(_ body: @escaping () -> Void) {
        if let loop = context?.eventLoop {
            if loop.inEventLoop { body() } else { loop.execute(body) }
        } else {
            // not added yet: shared single-threaded group means caller is on our future loop
            body()
        }
    }
}

public final class LocalForward {
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
    ) async throws -> LocalForward {
        precondition(config.type == "local", "only -L supported in v0.1")
        // Reach the gateway through its own bastion chain, if it has one.
        let parent = try await SSHConnection.connectParentChain(
            hops: hops, target: session, hostKeys: hostKeys)
        let ssh = try await parent.pipeline.handler(type: NIOSSHHandler.self).get()

        let bootstrap = ServerBootstrap(group: SSHRuntime.group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { local in
                let (localGlue, sshGlue) = GlueHandler.matchedPair()
                // Half-closure on this side too, so an EOF in either direction
                // is passed on instead of ending the whole connection.
                return local.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .flatMap { local.pipeline.addHandler(localGlue) }.flatMap {
                    let promise = parent.eventLoop.makePromise(of: Channel.self)
                    let channelType = SSHChannelType.directTCPIP(.init(
                        targetHost: config.targetHost,
                        targetPort: config.targetPort,
                        originatorAddress: local.remoteAddress
                            ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                    ))
                    ssh.createChannel(promise, channelType: channelType) { child, _ in
                        child.pipeline.addHandlers([SSHDataCodec(), sshGlue])
                    }
                    promise.futureResult.whenFailure { _ in local.close(promise: nil) }
                    return local.eventLoop.makeSucceededVoidFuture()
                }
            }
        do {
            let server = try await bootstrap.bind(host: config.bindHost, port: config.bindPort).get()
            return LocalForward(config: config, parent: parent, server: server)
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

// MARK: - Remote (-R) forwarding

public final class RemoteForward {
    public let config: TunnelConfig
    private let parentChannel: Channel
    /// Port the server actually bound (differs from config.bindPort when 0).
    public let boundPort: Int

    private init(config: TunnelConfig, parent: Channel, boundPort: Int) {
        self.config = config
        self.parentChannel = parent
        self.boundPort = boundPort
    }

    public static func start(
        config: TunnelConfig,
        session: SessionConfig,
        hostKeys: HostKeyVerification? = nil
    ) async throws -> RemoteForward {
        precondition(config.type == "remote", "RemoteForward requires type == remote")
        let privateKey = try SSHConnection.loadPrivateKey(session)
        let auth = UserAuthDelegate(
            username: session.username,
            password: session.password,
            privateKey: privateKey
        )

        let targetHost = config.targetHost
        let targetPort = config.targetPort
        // Server-initiated forwarded-tcpip channel -> TCP connection to target.
        let childInit: @Sendable (Channel, SSHChannelType) -> EventLoopFuture<Void> = { child, type in
            guard case .forwardedTCPIP = type else {
                return child.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
            }
            let (sshGlue, localGlue) = GlueHandler.matchedPair()
            return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.pipeline.addHandlers([SSHDataCodec(), sshGlue])
            }.map {
                ClientBootstrap(group: SSHRuntime.group)
                    .channelInitializer { $0.pipeline.addHandler(localGlue) }
                    .connect(host: targetHost, port: targetPort)
                    .whenFailure { _ in child.close(promise: nil) }
            }
        }

        let parent = try await SSHConnection.connectParent(
            config: session, auth: auth, hostKeys: hostKeys,
            inboundChildInitializer: childInit
        )
        do {
            let ssh = try await parent.pipeline.handler(type: NIOSSHHandler.self).get()
            let promise = parent.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            parent.eventLoop.execute {
                ssh.sendTCPForwardingRequest(
                    .listen(host: config.bindHost, port: config.bindPort),
                    promise: promise
                )
            }
            let response = try await SSHConnection.withTimeout(
                promise.futureResult, on: parent.eventLoop,
                seconds: 8, what: "tcpip-forward request (server refused -R?)"
            )
            let bound = response?.boundPort ?? config.bindPort
            return RemoteForward(config: config, parent: parent, boundPort: bound)
        } catch {
            parent.close(promise: nil)
            throw error
        }
    }

    public func stop() {
        // Closing the connection tears down the server-side listener.
        parentChannel.close(promise: nil)
    }
}

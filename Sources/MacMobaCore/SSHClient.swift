// Interactive SSH shell connection built on SwiftNIO SSH.
// One SSHConnection per terminal pane (same model as the Electron version).

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public enum SSHError: Error, CustomStringConvertible {
    case invalidChannelType
    case authenticationFailed(String)
    case keyUnsupported(String)
    case notConnected
    case timeout(String)
    case hostKeyRejected(String)

    public var description: String {
        switch self {
        case .invalidChannelType: return "invalid channel type"
        case .authenticationFailed(let m): return "authentication failed: \(m)"
        case .keyUnsupported(let m): return "unsupported key: \(m)"
        case .notConnected: return "not connected"
        case .timeout(let m): return "timeout: \(m)"
        case .hostKeyRejected(let m): return "host key rejected: \(m)"
        }
    }
}

// Shared single-threaded event loop group: everything runs on one loop,
// which keeps handler state access race-free.
enum SSHRuntime {
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

// MARK: - Delegates

final class AcceptAllHostKeys: NIOSSHClientServerAuthenticationDelegate {
    // TODO(UI phase): surface host-key fingerprint to the user and pin it.
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String?
    private let privateKey: NIOSSHPrivateKey?
    private var triedKey = false
    private var triedPassword = false

    init(username: String, password: String?, privateKey: NIOSSHPrivateKey?) {
        self.username = username
        self.password = password
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if let key = privateKey, availableMethods.contains(.publicKey), !triedKey {
            triedKey = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "",
                offer: .privateKey(.init(privateKey: key))
            ))
            return
        }
        if let pw = password, availableMethods.contains(.password), !triedPassword {
            triedPassword = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "",
                offer: .password(.init(password: pw))
            ))
            return
        }
        nextChallengePromise.succeed(nil)
    }
}

// MARK: - Shell channel handler

final class ShellIOHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let onData: (Data) -> Void
    private let onExit: (String) -> Void
    private var exitFired = false

    init(onData: @escaping (Data) -> Void, onExit: @escaping (String) -> Void) {
        self.onData = onData
        self.onExit = onExit
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = channelData.data else { return }
        if let bytes = buf.readBytes(length: buf.readableBytes), !bytes.isEmpty {
            onData(Data(bytes))
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: promise)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fireExit("closed")
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fireExit("error: \(error)")
        context.close(promise: nil)
    }

    private func fireExit(_ why: String) {
        guard !exitFired else { return }
        exitFired = true
        onExit(why)
    }
}

/// Accumulates a command's output until the channel closes.
///
/// Both stdout and stderr are kept: when `mosh-server` fails, the reason is on
/// stderr, and reporting "no MOSH CONNECT line" while discarding the actual
/// explanation would be the least useful thing to do.
final class CommandOutputCollector: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let lock = NSLock()
    private var buffer = Data()
    private var promise: EventLoopPromise<String>?
    private var finished = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = channelData.data else { return }
        guard let bytes = buf.readBytes(length: buf.readableBytes), !bytes.isEmpty else { return }
        lock.lock(); buffer.append(contentsOf: bytes); lock.unlock()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))),
                      promise: promise)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete()
        context.close(promise: nil)
    }

    /// Waits for the command to finish, or gives up and returns whatever it
    /// said so far — a server that starts mosh-server and then hangs should
    /// still yield its MOSH CONNECT line rather than nothing.
    func output(timeoutSeconds: Int64, on eventLoop: EventLoop) async throws -> String {
        let promise = eventLoop.makePromise(of: String.self)
        lock.lock()
        if finished {
            let text = String(decoding: buffer, as: UTF8.self)
            lock.unlock()
            promise.succeed(text)
            return try await promise.futureResult.get()
        }
        self.promise = promise
        lock.unlock()

        eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) { [weak self] in
            self?.complete()
        }
        return try await promise.futureResult.get()
    }

    private func complete() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let text = String(decoding: buffer, as: UTF8.self)
        let waiting = promise
        promise = nil
        lock.unlock()
        waiting?.succeed(text)
    }
}

// MARK: - Public connection API

public final class SSHConnection {
    private let parentChannel: Channel
    private let sessionChannel: Channel

    private init(parent: Channel, session: Channel) {
        self.parentChannel = parent
        self.sessionChannel = session
    }

    /// Connect, authenticate, open a PTY + interactive shell.
    public static func connect(
        config: SessionConfig,
        cols: Int = 80,
        rows: Int = 24,
        hostKeys: HostKeyVerification? = nil,
        jumps: [SessionConfig] = [],
        onData: @escaping (Data) -> Void,
        onExit: @escaping (String) -> Void
    ) async throws -> SSHConnection {
        let parent = try await connectParentChain(hops: jumps, target: config,
                                                  hostKeys: hostKeys)
        do {
            let ioHandler = ShellIOHandler(onData: onData, onExit: onExit)
            let session = try await openSessionChannel(
                parent: parent, handler: ioHandler,
                timeoutSeconds: hostKeys == nil ? 8 : 180)
            try await requestShell(session: session, cols: cols, rows: rows)
            return SSHConnection(parent: parent, session: session)
        } catch {
            parent.close(promise: nil)
            if error is SSHError { throw error }
            throw SSHError.authenticationFailed(String(reflecting: error))
        }
    }

    public func write(_ data: Data) {
        var buf = sessionChannel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        sessionChannel.writeAndFlush(buf, promise: nil)
    }

    public func resize(cols: Int, rows: Int) {
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        sessionChannel.triggerUserOutboundEvent(event, promise: nil)
    }

    public func close() {
        sessionChannel.close(promise: nil)
        parentChannel.close(promise: nil)
    }

    // MARK: - Shared plumbing (also used by tunnels)

    static func connectParent(
        config: SessionConfig,
        auth: NIOSSHClientUserAuthenticationDelegate,
        hostKeys: HostKeyVerification? = nil,
        inboundChildInitializer: (@Sendable (Channel, SSHChannelType) -> EventLoopFuture<Void>)? = nil
    ) async throws -> Channel {
        let rejection = HostKeyRejection()
        let serverAuth: NIOSSHClientServerAuthenticationDelegate = hostKeys.map {
            VerifyingHostKeys(host: config.host, port: config.port,
                              verification: $0, rejection: rejection)
        } ?? AcceptAllHostKeys()
        let clientConfig = SSHClientConfiguration(
            userAuthDelegate: auth,
            serverAuthDelegate: serverAuth
        )
        let bootstrap = ClientBootstrap(group: SSHRuntime.group)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(clientConfig),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: inboundChildInitializer
                    )
                ])
            }
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            // Keep idle sessions alive through NAT/firewall timeouts.
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)

        // Gateway failover: try the primary address, then each fallback, moving
        // on only when the TCP connection itself cannot be made. Authentication
        // happens later — a reachable-but-wrong gateway is not retried here.
        let candidates = GatewayFailover.candidates(
            primaryHost: config.host, primaryPort: config.port,
            fallbacks: config.fallbackHosts ?? [])
        var lastError: Error?
        for candidate in candidates {
            do {
                let channel = try await bootstrap.connect(host: candidate.host,
                                                          port: candidate.port).get()
                rejection.onReject { channel.close(promise: nil) }
                return channel
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SSHError.timeout("no address to connect to")
    }

    /// ProxyJump (ssh -J): reach `config` through an already-connected bastion.
    ///
    /// A direct-tcpip channel on the bastion carries the second SSH session, so
    /// the inner pipeline is [codec, NIOSSHHandler] — the codec turns the
    /// channel's SSHChannelData into the plain bytes the inner handler expects.
    /// The returned channel behaves like any other parent connection.
    static func connectParentViaJump(
        config: SessionConfig,
        auth: NIOSSHClientUserAuthenticationDelegate,
        hostKeys: HostKeyVerification? = nil,
        jumpChannel: Channel
    ) async throws -> Channel {
        let rejection = HostKeyRejection()
        let serverAuth: NIOSSHClientServerAuthenticationDelegate = hostKeys.map {
            VerifyingHostKeys(host: config.host, port: config.port,
                              verification: $0, rejection: rejection)
        } ?? AcceptAllHostKeys()
        let clientConfig = SSHClientConfiguration(
            userAuthDelegate: auth,
            serverAuthDelegate: serverAuth
        )

        let jumpSSH = try await jumpChannel.pipeline.handler(type: NIOSSHHandler.self).get()
        let promise = jumpChannel.eventLoop.makePromise(of: Channel.self)
        let channelType = SSHChannelType.directTCPIP(.init(
            targetHost: config.host,
            targetPort: config.port,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        ))
        jumpChannel.eventLoop.execute {
            jumpSSH.createChannel(promise, channelType: channelType) { child, _ in
                child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                    child.pipeline.addHandlers([
                        SSHDataCodec(),
                        NIOSSHHandler(role: .client(clientConfig),
                                      allocator: child.allocator,
                                      inboundChildChannelInitializer: nil),
                    ])
                }
            }
        }
        let inner = try await withTimeout(promise.futureResult, on: jumpChannel.eventLoop,
                                          seconds: 20,
                                          what: "open jump channel to \(config.host):\(config.port)")
        rejection.onReject { inner.close(promise: nil) }
        // Losing the bastion must tear down everything riding on it.
        jumpChannel.closeFuture.whenComplete { _ in inner.close(promise: nil) }
        return inner
    }

    /// Reach `target` through a chain of bastions, opening the outermost hop
    /// directly and tunnelling each inner hop through the previous — `ssh -J`,
    /// but as many hops deep as `hops` describes (empty = a direct connection).
    /// `hops` must be outermost first, as `JumpChain.resolve` produces.
    static func connectParentChain(
        hops: [SessionConfig],
        target: SessionConfig,
        hostKeys: HostKeyVerification? = nil
    ) async throws -> Channel {
        func auth(_ s: SessionConfig) throws -> UserAuthDelegate {
            UserAuthDelegate(username: s.username, password: s.password,
                             privateKey: try loadPrivateKey(s))
        }
        guard let first = hops.first else {
            return try await connectParent(config: target, auth: try auth(target),
                                           hostKeys: hostKeys)
        }
        // Closing the outermost channel cascades to every hop tunnelled through
        // it (each connectParentViaJump wires that up), so one close cleans up
        // the whole chain if any inner hop or the target fails.
        let outermost = try await connectParent(config: first, auth: try auth(first),
                                                hostKeys: hostKeys)
        do {
            var channel = outermost
            for hop in hops.dropFirst() {
                channel = try await connectParentViaJump(config: hop, auth: try auth(hop),
                                                         hostKeys: hostKeys, jumpChannel: channel)
            }
            let parent = try await connectParentViaJump(config: target, auth: try auth(target),
                                                        hostKeys: hostKeys, jumpChannel: channel)
            // The bastion→inner direction is already wired by connectParentViaJump;
            // wire inner→outermost too, so closing the target (all a caller holds)
            // tears the whole chain down instead of leaking the bastions.
            parent.closeFuture.whenComplete { _ in outermost.close(promise: nil) }
            return parent
        } catch {
            outermost.close(promise: nil)
            throw error
        }
    }

    /// `timeoutSeconds` is a backstop only: a server that closes the transport
    /// on bad credentials still fails fast via the closeFuture path below.
    /// Callers that may show a host-key prompt pass a long timeout, since the
    /// user could be comparing a fingerprint by hand.
    static func openSessionChannel(parent: Channel, handler: ChannelHandler,
                                   timeoutSeconds: Int64 = 8) async throws -> Channel {
        let ssh = try await parent.pipeline.handler(type: NIOSSHHandler.self).get()
        let promise = parent.eventLoop.makePromise(of: Channel.self)
        ssh.createChannel(promise) { child, channelType in
            guard channelType == .session else {
                return child.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
            }
            return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.pipeline.addHandlers([handler])
            }
        }
        // If the transport dies during auth (e.g. wrong password), fail fast
        // instead of hanging until the timeout. Everything runs on one loop,
        // so the `done` guard is race-free.
        let guarded = parent.eventLoop.makePromise(of: Channel.self)
        parent.eventLoop.execute {
            var done = false
            promise.futureResult.whenComplete { result in
                guard !done else { return }
                done = true
                switch result {
                case .success(let ch): guarded.succeed(ch)
                case .failure(let err): guarded.fail(err)
                }
            }
            parent.closeFuture.whenComplete { _ in
                guard !done else { return }
                done = true
                guarded.fail(SSHError.authenticationFailed(
                    "connection closed during authentication (wrong credentials, or host key rejected?)"))
            }
        }
        return try await withTimeout(guarded.futureResult, on: parent.eventLoop,
                                     seconds: timeoutSeconds, what: "open session channel (auth?)")
    }

    /// Runs one command and returns everything it printed.
    ///
    /// Used to start `mosh-server` on the remote: Mosh's whole handshake is
    /// "run this over SSH and read back a port and a key". An exec channel is
    /// used rather than typing into a login shell, so the output is the
    /// command's own and not tangled with a prompt or a motd.
    public static func runCommand(
        _ command: String,
        config: SessionConfig,
        hostKeys: HostKeyVerification? = nil,
        jumps: [SessionConfig] = [],
        timeoutSeconds: Int64 = 30
    ) async throws -> String {
        let parent = try await connectParentChain(hops: jumps, target: config,
                                                  hostKeys: hostKeys)
        defer { parent.close(promise: nil) }

        let collector = CommandOutputCollector()
        let session = try await openSessionChannel(
            parent: parent, handler: collector,
            timeoutSeconds: hostKeys == nil ? 8 : 180)
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        try await session.triggerUserOutboundEvent(exec).get()
        return try await collector.output(timeoutSeconds: timeoutSeconds,
                                          on: session.eventLoop)
    }

    private static func requestShell(session: Channel, cols: Int, rows: Int) async throws {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await session.triggerUserOutboundEvent(pty).get()
        let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await session.triggerUserOutboundEvent(shell).get()
    }

    static func loadPrivateKey(_ config: SessionConfig) throws -> NIOSSHPrivateKey? {
        switch config.authType {
        case "keyfile":
            guard let path = config.keyPath else { return nil }
            let expanded = NSString(string: path).expandingTildeInPath
            let pem = try String(contentsOfFile: expanded, encoding: .utf8)
            return try OpenSSHKeyParser.parse(pem: pem, passphrase: config.passphrase)
        case "keytext":
            guard let pem = config.keyData else { return nil }
            return try OpenSSHKeyParser.parse(pem: pem, passphrase: config.passphrase)
        default:
            return nil
        }
    }

    static func withTimeout<T>(
        _ future: EventLoopFuture<T>,
        on loop: EventLoop,
        seconds: Int64,
        what: String
    ) async throws -> T {
        let promise = loop.makePromise(of: T.self)
        let task = loop.scheduleTask(in: .seconds(seconds)) {
            promise.fail(SSHError.timeout(what))
        }
        future.whenComplete { result in
            task.cancel()
            switch result {
            case .success(let v): promise.succeed(v)
            case .failure(let e): promise.fail(e)
            }
        }
        return try await promise.futureResult.get()
    }
}

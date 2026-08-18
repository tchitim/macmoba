// How a VNC or RDP client reaches its server.
//
// Screen Sharing and the Microsoft client can only dial a host directly. The
// thing MacMoba adds is the SSH hop: point a session at a port bound to the
// remote machine's own localhost, or sitting behind a bastion, and this opens
// a direct-tcpip channel through a saved SSH session and hands back a local
// endpoint that speaks to it.

import Foundation

public final class RemoteDesktopRoute {
    /// Where the viewer should actually connect.
    public let host: String
    public let port: Int
    /// True when the endpoint is a local tunnel rather than the real host.
    public let isTunnelled: Bool

    private let forward: LocalForward?

    private init(host: String, port: Int, forward: LocalForward?) {
        self.host = host
        self.port = port
        self.forward = forward
        self.isTunnelled = forward != nil
    }

    /// Open a route to `target`. When `via` is given the connection is carried
    /// over that SSH session; otherwise it is a plain direct connection and no
    /// tunnel is started at all.
    public static func open(
        target: SessionConfig,
        via ssh: SessionConfig?,
        viaHops: [SessionConfig] = [],
        hostKeys: HostKeyVerification? = nil
    ) async throws -> RemoteDesktopRoute {
        guard let ssh else {
            return RemoteDesktopRoute(host: target.host, port: target.port, forward: nil)
        }
        // Bind port 0: the OS picks a free port and LocalForward reports which,
        // so two tunnelled sessions never collide.
        let tunnel = TunnelConfig(
            id: "remote-desktop-\(target.id)",
            name: "\(target.name) via \(ssh.name)",
            type: "local",
            sessionId: ssh.id,
            bindHost: "127.0.0.1",
            bindPort: 0,
            targetHost: target.host,
            targetPort: target.port
        )
        let forward = try await LocalForward.start(config: tunnel, session: ssh,
                                                   via: viaHops, hostKeys: hostKeys)
        return RemoteDesktopRoute(host: "127.0.0.1", port: forward.localPort, forward: forward)
    }

    public func close() {
        forward?.stop()
    }
}

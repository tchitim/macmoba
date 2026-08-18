// Is a host actually up? A dashboard full of connections is only useful if it
// tells you which ones are reachable before you try, so this does the cheapest
// honest check there is: open a TCP connection to the port and see whether it
// completes. No login, no protocol — just "did the three-way handshake finish
// within the timeout", which is exactly what a status light should mean.
//
// The connect is non-blocking + poll() so a dead host fails on the timeout
// instead of the kernel's minute-long default, and so the probe never blocks
// the thread it runs on for longer than asked.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The result of one reachability check.
public enum Reachability: Equatable, Sendable {
    /// Handshake completed; `latencyMs` is how long it took.
    case up(latencyMs: Int)
    /// Could not connect — DNS failure, refused, timed out. `reason` is short.
    case down(reason: String)

    public var isUp: Bool { if case .up = self { return true }; return false }
}

public enum ReachabilityProbe {
    /// Try to open a TCP connection to `host:port`, giving up after `timeout`
    /// seconds. Safe to call off the main thread; it blocks only up to the
    /// timeout. `host` may be a name or a literal v4/v6 address.
    public static func check(host: String, port: Int, timeout: TimeInterval = 2.0) -> Reachability {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC          // v4 or v6, whichever resolves
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var info: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &info)
        guard gai == 0, let first = info else {
            return .down(reason: "cannot resolve \(host)")
        }
        defer { freeaddrinfo(info) }

        let start = Date()
        var lastReason = "no address"
        // A name can resolve to several addresses; the host is up if any answers.
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let addr = node {
            switch attempt(addr.pointee, timeout: timeout, since: start) {
            case .up(let ms): return .up(latencyMs: ms)
            case .down(let reason): lastReason = reason
            }
            node = addr.pointee.ai_next
        }
        return .down(reason: lastReason)
    }

    private static func attempt(_ addr: addrinfo, timeout: TimeInterval, since start: Date) -> Reachability {
        let fd = socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol)
        guard fd >= 0 else { return .down(reason: "socket: \(errnoText())") }
        defer { Darwin.close(fd) }

        // Non-blocking so connect() returns immediately and we bound the wait.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = connect(fd, addr.ai_addr, addr.ai_addrlen)
        if rc == 0 {
            return .up(latencyMs: elapsedMs(since: start))   // connected instantly (localhost)
        }
        guard errno == EINPROGRESS else {
            return .down(reason: connectErrorText())
        }

        // Wait for the socket to become writable, i.e. the handshake to finish.
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(max(1, timeout * 1000))
        let ready = poll(&pfd, 1, ms)
        if ready == 0 {
            return .down(reason: "timed out after \(Int(timeout))s")
        }
        if ready < 0 {
            return .down(reason: "poll: \(errnoText())")
        }
        // Writable — but that includes "failed". SO_ERROR holds the verdict.
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        if soErr == 0 {
            return .up(latencyMs: elapsedMs(since: start))
        }
        return .down(reason: String(cString: strerror(soErr)))
    }

    private static func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
    private static func connectErrorText() -> String {
        if errno == ECONNREFUSED { return "connection refused" }
        return String(cString: strerror(errno))
    }
}

public extension SessionConfig {
    /// What a health check should dial for this session, or nil if a TCP probe
    /// is meaningless for it. Serial has no network endpoint; a web session is
    /// a URL whose real host/port live in `webURL`, not the host field, and its
    /// reachability is the browser's business.
    var reachabilityTarget: (host: String, port: Int)? {
        switch sessionKind {
        case .serial, .web: return nil
        default:
            guard !host.isEmpty else { return nil }
            return (host, port)
        }
    }
}

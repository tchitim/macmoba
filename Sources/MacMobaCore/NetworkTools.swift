// The small "Tools" that MobaXterm keeps a menu for: wake a machine, see which
// ports are open, resolve a name. Each is a plain function with no UI, so the
// panel is thin and the logic is testable — the magic-packet bytes, the scan
// result, the resolved addresses are all checkable without a network.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Wake-on-LAN

public enum WakeOnLAN {
    /// The 102-byte magic packet for `mac`: six 0xFF bytes then the MAC repeated
    /// sixteen times. Returns nil if the MAC is not six hex octets. Accepts
    /// `aa:bb:cc:dd:ee:ff`, `aa-bb-...`, or bare `aabbccddeeff`.
    public static func magicPacket(mac: String) -> Data? {
        guard let bytes = parseMAC(mac) else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    public static func parseMAC(_ mac: String) -> [UInt8]? {
        let cleaned = mac.filter { $0.isHexDigit }
        guard cleaned.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    public enum WakeError: Error { case badMAC, socketFailed, sendFailed }

    /// Broadcast the magic packet on UDP `port` (9 by convention). Best-effort:
    /// WoL is fire-and-forget, so a successful send is all that can be promised.
    public static func send(mac: String, broadcast: String = "255.255.255.255",
                            port: UInt16 = 9) throws {
        guard let packet = magicPacket(mac: mac) else { throw WakeError.badMAC }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WakeError.socketFailed }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(broadcast)
        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { throw WakeError.sendFailed }
    }
}

// MARK: - Port scan

public enum PortScanner {
    /// Which of `ports` on `host` accept a TCP connection within `timeout`.
    /// Runs the probes concurrently (bounded by the system width) and returns
    /// the open ports in ascending order. Reuses the same connect check the
    /// health monitor uses.
    public static func scan(host: String, ports: [Int], timeout: TimeInterval = 1.0) -> [Int] {
        guard !ports.isEmpty else { return [] }
        let lock = NSLock()
        var open: [Int] = []
        DispatchQueue.concurrentPerform(iterations: ports.count) { i in
            if ReachabilityProbe.check(host: host, port: ports[i], timeout: timeout).isUp {
                lock.lock(); open.append(ports[i]); lock.unlock()
            }
        }
        return open.sorted()
    }

    /// A handful of the ports worth checking first on an unknown host.
    public static let commonPorts = [22, 23, 21, 80, 443, 3389, 5900, 8080, 445, 139, 3306, 5432]
}

// MARK: - DNS

public enum DNSLookup {
    /// Resolve `host` to its IPv4/IPv6 addresses as strings, in the order the
    /// resolver returns them, deduplicated. Empty if it does not resolve.
    public static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return [] }
        defer { freeaddrinfo(info) }

        var results: [String] = []
        var seen = Set<String>()
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let addr = node {
            if let text = addressString(addr.pointee), seen.insert(text).inserted {
                results.append(text)
            }
            node = addr.pointee.ai_next
        }
        return results
    }

    private static func addressString(_ addr: addrinfo) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr.ai_addr, addr.ai_addrlen, &buffer,
                          socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}

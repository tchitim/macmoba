// When macOS sends a request DIRECT even though a proxy is configured.
//
// A web tab that says "via bastion" is making a claim about where the traffic
// went, and that claim has to be true. macOS applies the usual proxy-exception
// rule: loopback, and anything on a network this Mac is directly attached to,
// skips the proxy entirely. Measured against a logging SOCKS proxy on
// macOS 26: a hostname is proxied, a public IP literal is proxied, an off-subnet
// private literal like 10.99.99.99 is proxied — but 127.0.0.1 and an address on
// the Mac's own Wi-Fi subnet are not.
//
// That rule is sensible (there is no point tunnelling to your own LAN) and it
// cannot be turned off through ProxyConfiguration: neither matchDomains nor
// allowFailover changes it. So instead of pretending, the tab says so.

import Foundation

public enum ProxyBypass {
    /// One of this Mac's own IPv4 interfaces.
    public struct LocalNetwork: Equatable, Sendable {
        public let address: String
        public let netmask: String
        public init(address: String, netmask: String) {
            self.address = address
            self.netmask = netmask
        }
    }

    /// Whether macOS will ignore the proxy for `host` and connect directly.
    ///
    /// Only IP literals can be bypassed: a name is handed to the proxy to
    /// resolve, which is why an internal hostname tunnels correctly even when
    /// it happens to point at a local-looking address.
    public static func sendsDirect(host rawHost: String,
                                   localNetworks: [LocalNetwork]) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if host == "localhost" || host == "::1" { return true }
        guard let target = ipv4(host) else {
            // A hostname, or IPv6 — handed to the proxy.
            return false
        }
        if target >> 24 == 127 { return true }

        for network in localNetworks {
            guard let address = ipv4(network.address),
                  let mask = ipv4(network.netmask), mask != 0 else { continue }
            if address & mask == target & mask { return true }
        }
        return false
    }

    /// Dotted-quad to a number, or nil when it is not an IPv4 literal.
    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let byte = UInt32(part), byte <= 255 else { return nil }
            value = value << 8 | byte
        }
        return value
    }

    /// This Mac's IPv4 interfaces, for passing to `sendsDirect`.
    public static func localNetworks() -> [LocalNetwork] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [LocalNetwork] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let netmask = interface.pointee.ifa_netmask,
                  interface.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            guard let address = presentation(addr), let mask = presentation(netmask)
            else { continue }
            found.append(LocalNetwork(address: address, netmask: mask))
        }
        return found
    }

    private static func presentation(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer -> String? in
            var sin_addr = pointer.pointee.sin_addr
            guard inet_ntop(AF_INET, &sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil
            else { return nil }
            return String(cString: buffer)
        }
        return result
    }
}

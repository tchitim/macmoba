// The live part of Bonjour discovery: browse for the known service types,
// resolve each to a host and port, and report the running list.
//
// NetService is the older API but the right shape here — it resolves a service
// straight to a hostname and port, which Network.framework's NWBrowser makes
// you open a connection to obtain. Everything runs on the main runloop, so a
// test can advertise a service with `dns-sd` and see it appear.

import Foundation

@MainActor
public final class BonjourBrowser: NSObject {
    /// Called on the main actor whenever the discovered set changes.
    public var onChange: (([DiscoveredService]) -> Void)?

    private var browsers: [NetServiceBrowser] = []
    /// Services still resolving are held so ARC does not release them mid-lookup.
    private var resolving: Set<NetService> = []
    private var found: [String: DiscoveredService] = [:]   // id -> service

    public var services: [DiscoveredService] {
        found.values.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    public override init() { super.init() }

    /// Start browsing. Pass a subset of kinds to narrow the search.
    public func start(kinds: [BonjourServiceKind] = BonjourServiceKind.allCases) {
        stop()
        for kind in kinds {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: kind.serviceType, inDomain: "local.")
            browsers.append(browser)
        }
    }

    public func stop() {
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
    }

    private func publish() { onChange?(services) }
}

extension BonjourBrowser: NetServiceBrowserDelegate {
    public nonisolated func netServiceBrowser(_ browser: NetServiceBrowser,
                                              didFind service: NetService,
                                              moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            resolving.insert(service)
            service.resolve(withTimeout: 5)
        }
    }

    public nonisolated func netServiceBrowser(_ browser: NetServiceBrowser,
                                              didRemove service: NetService,
                                              moreComing: Bool) {
        MainActor.assumeIsolated {
            guard let kind = BonjourServiceKind.from(serviceType: service.type) else { return }
            found = found.filter { !($0.value.kind == kind && $0.value.name == service.name) }
            publish()
        }
    }
}

extension BonjourBrowser: NetServiceDelegate {
    public nonisolated func netServiceDidResolveAddress(_ service: NetService) {
        MainActor.assumeIsolated {
            resolving.remove(service)
            guard let kind = BonjourServiceKind.from(serviceType: service.type),
                  service.port > 0 else { return }
            // Prefer the advertised .local hostname; fall back to a resolved IP.
            let host = service.hostName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
                ?? Self.firstAddress(of: service)
            guard let host, !host.isEmpty else { return }
            let discovered = DiscoveredService(name: service.name, kind: kind,
                                               host: host, port: service.port)
            found[discovered.id] = discovered
            publish()
        }
    }

    public nonisolated func netService(_ service: NetService,
                                       didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated { resolving.remove(service) }
    }

    /// The first IPv4/IPv6 literal from a resolved service, for when it has no
    /// hostname (rare, but seen with some appliances).
    private static func firstAddress(of service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for data in addresses {
            let host = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(sa, socklen_t(data.count), &buffer,
                                         socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                return result == 0 ? String(cString: buffer) : nil
            }
            if let host, !host.hasPrefix("fe80") { return host }   // skip link-local
        }
        return nil
    }
}

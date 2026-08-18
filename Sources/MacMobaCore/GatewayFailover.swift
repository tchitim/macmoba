// The list of addresses to try, in order, when connecting a gateway that has
// standbys.
//
// A `fallbackHosts` entry is "host" (reuse the primary port) or "host:port".
// The primary comes first, then the fallbacks in the order given, with exact
// duplicates removed so a copy-pasted list does not dial the same box twice.
// Failover is for *reachability* only: the caller moves to the next candidate
// when a connection cannot be made, never on an authentication failure — a
// wrong password on the right gateway is not a reason to try another host.

import Foundation

public enum GatewayFailover {
    public struct Candidate: Equatable, Sendable {
        public let host: String
        public let port: Int
        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public static func candidates(primaryHost: String, primaryPort: Int,
                                  fallbacks: [String]) -> [Candidate] {
        var result = [Candidate(host: primaryHost, port: primaryPort)]
        for raw in fallbacks {
            guard let candidate = parse(raw, defaultPort: primaryPort) else { continue }
            if !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }

    /// "host" -> (host, defaultPort); "host:port" -> (host, port). IPv6 in
    /// brackets keeps its own colons: "[::1]:22". Nil for blanks or a bad port.
    static func parse(_ raw: String, defaultPort: Int) -> Candidate? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // Bracketed IPv6, optionally with a trailing :port.
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return Candidate(host: host, port: defaultPort) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()),
                  (1...65535).contains(port) else { return nil }
            return Candidate(host: host, port: port)
        }
        // A single colon means host:port; more than one is a bare IPv6 literal.
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port),
                  !parts[0].isEmpty else { return nil }
            return Candidate(host: String(parts[0]), port: port)
        }
        return Candidate(host: text, port: defaultPort)
    }
}

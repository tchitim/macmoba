// Name-to-address overrides for a tunnelled connection.
//
// The case this exists for: an internal host that neither this Mac nor the
// jump host can resolve, but whose address is known. Chrome solves it with
// `--host-resolver-rules="MAP name 10.0.0.1"`, and the reason that flag maps
// rather than simply substituting the address in the URL is that the NAME
// still has to travel — TLS checks the certificate against it, and a server
// hosting several sites picks between them by SNI and the Host header.
//
// The same distinction applies here. This is consulted where a SOCKS CONNECT
// is turned into a channel, so only the destination changes; the browser is
// never told, and goes on sending the name it was given.
//
// A rule may name a port too — `name = 10.0.0.1:8443` — for a service that
// does not sit where the URL says. Chrome's flag takes the same form.

import Foundation

public struct HostOverrides: Sendable, Equatable {
    /// An address, and optionally a port to go with it.
    public struct Target: Sendable, Equatable {
        public let host: String
        /// Nil means "whatever port was asked for" — the common case. A rule
        /// only names a port when the service sits somewhere other than where
        /// the URL says.
        public let port: Int?

        public init(host: String, port: Int? = nil) {
            self.host = host
            self.port = port
        }

        /// Splits `10.0.0.1:8443`, `[::1]:8443`, `10.0.0.1` or `::1`.
        ///
        /// A bare IPv6 literal is full of colons, so the last one is only a
        /// port separator when the address is bracketed — which is exactly the
        /// rule Chrome's flag follows, and the one anyone who has written a
        /// URL already knows.
        public init(parsing text: String) {
            if text.hasPrefix("["), let close = text.lastIndex(of: "]") {
                let inner = String(text[text.index(after: text.startIndex)..<close])
                let rest = text[text.index(after: close)...]
                self.init(host: inner, port: Self.port(after: rest))
                return
            }
            let colons = text.filter { $0 == ":" }.count
            if colons == 1, let colon = text.lastIndex(of: ":") {
                let port = Self.port(after: text[colon...])
                if port != nil {
                    self.init(host: String(text[..<colon]), port: port)
                    return
                }
            }
            self.init(host: text, port: nil)
        }

        /// The number after a leading ":", if the whole of it is one.
        ///
        /// Strict: "8443x" is not a port, and treating it as 8443 would dial
        /// somewhere the rule never said.
        private static func port(after text: Substring) -> Int? {
            guard text.hasPrefix(":") else { return nil }
            let digits = text.dropFirst()
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
                  let value = Int(digits), (1...65535).contains(value) else { return nil }
            return value
        }

        public var text: String {
            let base = host.contains(":") ? "[\(host)]" : host
            return port.map { "\(base):\($0)" } ?? base
        }
    }

    /// Lowercased name -> target.
    private let map: [String: Target]

    public init(_ map: [String: String] = [:]) {
        self.map = Dictionary(uniqueKeysWithValues: map.map {
            ($0.key.lowercased(), Target(parsing: $0.value))
        })
    }

    public var isEmpty: Bool { map.isEmpty }

    /// Where to dial for `host` on `port`, or the pair unchanged.
    ///
    /// Case-insensitive, because host names are, and a rule that quietly
    /// missed on capitalisation would look exactly like no rule at all.
    public func resolve(_ host: String, port: Int) -> (host: String, port: Int) {
        guard let target = map[host.lowercased()] else { return (host, port) }
        return (target.host, target.port ?? port)
    }

    /// The address alone, for a caller that is not changing the port.
    public func resolve(_ host: String) -> String {
        map[host.lowercased()]?.host ?? host
    }

    /// Parses one rule per line, `name = address` or `name address`.
    ///
    /// Deliberately forgiving about spacing and separators, because this is
    /// typed into a text box, and strict about what it accepts as a pair: a
    /// line that is not one is skipped rather than guessed at. `#` starts a
    /// comment so a rule can be turned off without deleting it.
    public static func parse(_ text: String) -> HostOverrides {
        var map: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: { $0 == "=" || $0 == " " || $0 == "\t" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Exactly two: "a b c" is not a rule anyone meant, and picking two
            // of the three would act on a guess.
            guard parts.count == 2 else { continue }
            let (name, address) = (parts[0], parts[1])
            guard !name.isEmpty, !address.isEmpty else { continue }
            map[name] = address
        }
        return HostOverrides(map)
    }

    /// Back to the text form, one rule per line, for storing and editing.
    public var text: String {
        map.keys.sorted().map { "\($0) = \(map[$0]!.text)" }.joined(separator: "\n")
    }
}

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

import Foundation

public struct HostOverrides: Sendable, Equatable {
    /// Lowercased name -> address.
    private let map: [String: String]

    public init(_ map: [String: String] = [:]) {
        self.map = Dictionary(uniqueKeysWithValues: map.map { ($0.key.lowercased(), $0.value) })
    }

    public var isEmpty: Bool { map.isEmpty }

    /// The address to dial for `host`, or `host` itself.
    ///
    /// Case-insensitive, because host names are, and a rule that quietly
    /// missed on capitalisation would look exactly like no rule at all.
    public func resolve(_ host: String) -> String {
        map[host.lowercased()] ?? host
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
        map.keys.sorted().map { "\($0) = \(map[$0]!)" }.joined(separator: "\n")
    }
}

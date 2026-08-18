// Import hosts from ~/.ssh/config so existing SSH users don't retype
// everything (MobaXterm imports sessions the same way).
//
// Deliberately a small subset of the format: Host / HostName / User / Port /
// IdentityFile, plus `Include`. Wildcard patterns (Host *) are skipped — they
// are defaults, not connectable hosts.

import Foundation

public struct SSHConfigHost: Equatable, Sendable {
    public var alias: String
    public var hostName: String
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?
}

public enum SSHConfigImporter {
    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// Parse a config file, following `Include` directives one level deep.
    public static func parse(fileURL: URL, followIncludes: Bool = true) throws -> [SSHConfigHost] {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return parse(text: text, relativeTo: fileURL.deletingLastPathComponent(),
                     followIncludes: followIncludes)
    }

    public static func parse(text: String, relativeTo baseDir: URL? = nil,
                             followIncludes: Bool = false) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: SSHConfigHost?

        func flush() {
            guard var host = current else { return }
            // A Host block with no HostName still connects — to its own alias.
            if host.hostName.isEmpty { host.hostName = host.alias }
            hosts.append(host)
            current = nil
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // Keywords are case-insensitive; `=` is allowed instead of space.
            let parts = line.replacingOccurrences(of: "=", with: " ")
                .split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let keyword = parts[0].lowercased()
            let value = parts.dropFirst().joined(separator: " ")

            switch keyword {
            case "host":
                flush()
                // "Host a b" defines several aliases; take the first concrete one.
                let aliases = parts.dropFirst().map(String.init)
                guard let alias = aliases.first(where: { !$0.contains("*") && !$0.contains("?") })
                else { continue }
                current = SSHConfigHost(alias: alias, hostName: "")
            case "hostname":
                current?.hostName = value
            case "user":
                current?.user = value
            case "port":
                current?.port = Int(value)
            case "identityfile":
                current?.identityFile = (value as NSString).expandingTildeInPath
            case "proxyjump":
                // "none" explicitly clears an inherited jump; treat as no jump.
                current?.proxyJump = value.lowercased() == "none" ? nil : value
            case "include":
                guard followIncludes, let baseDir else { continue }
                let path = (value as NSString).expandingTildeInPath
                let url = path.hasPrefix("/")
                    ? URL(fileURLWithPath: path)
                    : baseDir.appendingPathComponent(path)
                // One level only, and never fail the whole import on a bad include.
                if let included = try? parse(fileURL: url, followIncludes: false) {
                    hosts.append(contentsOf: included)
                }
            default:
                continue
            }
        }
        flush()
        return hosts
    }

    /// Turn parsed hosts into sessions, skipping ones already in the vault
    /// (matched on host+port+user so re-importing is safe).
    public static func sessions(from hosts: [SSHConfigHost], existing: [SessionConfig],
                                group: String? = "SSH Config") -> [SessionConfig] {
        let taken = Set(existing.map { "\($0.username)@\($0.host):\($0.port)" })
        let fallbackUser = NSUserName()
        return hosts.compactMap { host in
            let user = host.user ?? fallbackUser
            let port = host.port ?? 22
            guard !taken.contains("\(user)@\(host.hostName):\(port)") else { return nil }
            return SessionConfig(
                name: host.alias,
                host: host.hostName,
                port: port,
                username: user,
                authType: host.identityFile != nil ? "keyfile" : "password",
                keyPath: host.identityFile,
                group: group,
                proxyJump: host.proxyJump
            )
        }
    }
}

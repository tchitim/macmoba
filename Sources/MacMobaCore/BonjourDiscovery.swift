// Finding remote-access services advertised on the local network with Bonjour,
// and turning them into sessions.
//
// A Mac with Remote Login on advertises _ssh._tcp; Screen Sharing advertises
// _rfb._tcp; a NAS its _sftp-ssh._tcp and _ftp._tcp. Browsing for these means a
// new machine on the LAN can be connected to without anyone typing an address.
//
// The service-type ↔ SessionKind mapping and the "make a session from what was
// found" step are pure and testable; the browsing itself (NetService, a runloop
// and delegates) is thin and lives alongside so a test can drive it against a
// service advertised with `dns-sd`.

import Foundation

/// The Bonjour service types MacMoba knows how to connect to.
public enum BonjourServiceKind: String, CaseIterable, Sendable {
    case ssh = "_ssh._tcp."
    case sftp = "_sftp-ssh._tcp."
    case vnc = "_rfb._tcp."
    case rdp = "_rdp._tcp."
    case telnet = "_telnet._tcp."
    case ftp = "_ftp._tcp."

    /// NetService wants the type without the trailing domain dot.
    public var serviceType: String { String(rawValue.dropLast()) }

    /// What kind of MacMoba session this becomes. SFTP is reached through an SSH
    /// session's file browser, so it maps to an SSH session.
    public var sessionKind: SessionKind {
        switch self {
        case .ssh, .sftp: return .ssh
        case .vnc: return .vnc
        case .rdp: return .rdp
        case .telnet: return .telnet
        case .ftp: return .ftp
        }
    }

    /// Match a discovered service's type (with or without the trailing dot).
    public static func from(serviceType type: String) -> BonjourServiceKind? {
        let normalized = type.hasSuffix(".") ? type : type + "."
        return allCases.first { $0.rawValue == normalized }
    }
}

/// A service found on the network, resolved to something connectable.
public struct DiscoveredService: Equatable, Sendable, Identifiable {
    public let name: String
    public let kind: BonjourServiceKind
    public let host: String
    public let port: Int

    public var id: String { "\(kind.rawValue)|\(name)|\(host):\(port)" }

    public init(name: String, kind: BonjourServiceKind, host: String, port: Int) {
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
    }

    /// A session ready to save or connect. The Bonjour name becomes the session
    /// name; there is no username or password to discover, so those are left for
    /// the user (or a shared credential) to supply.
    public func makeSession() -> SessionConfig {
        SessionConfig(name: name, host: host, port: port,
                      username: "", authType: "password",
                      kind: kind.sessionKind == .ssh ? nil : kind.sessionKind.rawValue)
    }
}

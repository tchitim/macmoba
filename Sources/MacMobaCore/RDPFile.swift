// Reading Microsoft .rdp connection files.
//
// These come from mstsc, from Windows Admin Center, and — the reason this
// exists — from CyberArk PSM, which hands out a generated .rdp per session.
//
// The format is one setting per line, `name:type:value`, where the type is
// `s` (string), `i` (integer) or `b` (a base64 blob). Two things bite:
//
//   * The file is usually UTF-16 with a byte-order mark, not UTF-8. Read as
//     UTF-8 it looks like every character has a NUL after it and nothing
//     parses.
//   * `password 51:b:` is encrypted with Windows DPAPI, tied to the user
//     account and machine that wrote it. It cannot be decrypted anywhere else,
//     so it is reported rather than silently ignored.

import Foundation

public struct RDPFile: Sendable {
    /// Every setting, keyed by its lower-cased name.
    public var settings: [String: String] = [:]
    /// Things the file asks for that MacMoba cannot do, in words worth showing.
    public var warnings: [String] = []

    public func string(_ key: String) -> String? {
        let value = settings[key.lowercased()]
        return (value?.isEmpty ?? true) ? nil : value
    }

    public func integer(_ key: String) -> Int? {
        settings[key.lowercased()].flatMap(Int.init)
    }

    public func flag(_ key: String) -> Bool? {
        integer(key).map { $0 != 0 }
    }
}

public enum RDPFileParser {
    /// Decode the bytes of a .rdp file.
    ///
    /// Windows writes these as UTF-16LE with a BOM by default. The BOM is
    /// checked first, then UTF-8, and finally Latin-1 — which cannot fail, so
    /// a file with one odd byte still parses instead of being rejected whole.
    public static func decode(_ data: Data) -> String {
        if data.count >= 2 {
            let first = data[data.startIndex], second = data[data.startIndex + 1]
            if first == 0xFF, second == 0xFE {
                return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
            }
            if first == 0xFE, second == 0xFF {
                return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
            }
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return text
        }
        // NULs before UTF-8, not after. UTF-16 ASCII is "f\0u\0l\0l\0…",
        // which IS valid UTF-8 — NUL is a legal character — so trying UTF-8
        // first "succeeds" and hands back a string full of NULs that parses
        // to nothing. Which side the NULs fall on says LE or BE.
        if data.count > 1, data.prefix(64).contains(0x00) {
            let firstIsNUL = data[data.startIndex] == 0x00
            let encoding: String.Encoding = firstIsNUL ? .utf16BigEndian : .utf16LittleEndian
            if let text = String(data: data, encoding: encoding), text.contains(":") {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(_ data: Data) -> RDPFile {
        parse(text: decode(data))
    }

    public static func parse(text: String) -> RDPFile {
        var file = RDPFile()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            // Split on the FIRST two colons only: the value routinely contains
            // more of them (`full address:s:host:3389`).
            let parts = line.split(separator: ":", maxSplits: 2,
                                   omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            file.settings[key] = String(parts[2])
        }
        return file
    }

    /// Turn a parsed file into a session, and say what could not be carried
    /// across.
    ///
    /// - Parameter name: what to call the session; the file has no name field,
    ///   so the caller passes the file's own name.
    public static func session(from file: RDPFile, name: String) -> (SessionConfig, [String]) {
        var warnings: [String] = []
        let (host, addressPort) = splitAddress(file.string("full address")
                                               ?? file.string("alternate full address") ?? "")
        // The port can arrive either way. CyberArk PSM writes a bare address
        // and a separate `server port`; mstsc usually folds it into the
        // address as host:port. The explicit key wins when both are there.
        let port = file.integer("server port").flatMap { (1...65535).contains($0) ? $0 : nil }
            ?? addressPort

        var username = file.string("username") ?? ""
        var domain = file.string("domain") ?? ""
        // Windows writes DOMAIN\user here as often as not.
        if let slash = username.firstIndex(of: "\\") {
            if domain.isEmpty { domain = String(username[username.startIndex..<slash]) }
            username = String(username[username.index(after: slash)...])
        }

        // Display. "screen mode id" 2 means full screen, which for us means
        // following the window rather than a fixed size.
        let fullScreen = file.integer("screen mode id") == 2
        let width = file.integer("desktopwidth")
        let height = file.integer("desktopheight")
        let useAllDisplays = file.flag("use multimon") ?? false
        var displayMode: RDPDisplayMode = .fitWindow
        if !fullScreen, let width, let height, width > 0, height > 0 {
            displayMode = .fixed
        }

        // CredSSP off means the server does not want NLA.
        let security: RDPSecurity? = file.flag("enablecredsspsupport").map { $0 ? .nla : .tls }

        // Things we cannot honour. Each one is worth saying out loud rather
        // than connecting and behaving oddly.
        if file.string("gatewayhostname") != nil,
           (file.integer("gatewayusagemethod") ?? 0) != 0 {
            warnings.append("This file uses an RD Gateway (\(file.string("gatewayhostname")!)), "
                            + "which MacMoba does not support. Connect to the host directly, "
                            + "or reach it through an SSH session.")
        }
        if file.settings["password 51"] != nil {
            warnings.append("The saved password in this file is encrypted by Windows (DPAPI) "
                            + "and can only be read on the PC that created it. "
                            + "Enter the password here instead.")
        }
        if file.flag("remoteapplicationmode") == true {
            let app = file.string("remoteapplicationprogram") ?? "an app"
            warnings.append("This file opens a single published app (\(app)). "
                            + "MacMoba opens the full desktop instead.")
        }
        if let shell = file.string("alternate shell") {
            // CyberArk PSM puts its routing here — "psm /u user /a target /c
            // component" — so it is carried across rather than dropped.
            warnings.append("Start program carried across: \(shell)")
        }
        if file.string("loadbalanceinfo") != nil {
            warnings.append("This file carries load-balance routing (loadbalanceinfo), "
                            + "which MacMoba does not send. If the far end is a broker or "
                            + "PSM farm, the connection may land on the wrong host.")
        }
        if let drives = file.string("drivestoredirect") {
            warnings.append("The file redirects Windows drives (\(drives)). "
                            + "Add the Mac folders you want to share in the session editor.")
        }

        var config = SessionConfig(
            name: name,
            host: host,
            port: port ?? SessionKind.rdp.defaultPort,
            username: username,
            authType: "password",
            kind: SessionKind.rdp.rawValue,
            domain: domain.isEmpty ? nil : domain,
            rdpSecurity: security == .negotiate ? nil : security?.rawValue,
            rdpDisplayMode: displayMode == .fitWindow ? nil : displayMode.rawValue,
            rdpWidth: displayMode == .fixed ? width : nil,
            rdpHeight: displayMode == .fixed ? height : nil,
            rdpUseAllDisplays: useAllDisplays ? true : nil)
        config.rdpAlternateShell = file.string("alternate shell")
        return (config, warnings)
    }

    /// `host`, `host:3389`, or `[::1]:3389`.
    static func splitAddress(_ address: String) -> (host: String, port: Int?) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ("", nil) }
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) { return (host, port) }
            return (host, nil)
        }
        // Split on the LAST colon so a bare IPv6 address stays intact.
        guard let colon = trimmed.lastIndex(of: ":") else { return (trimmed, nil) }
        let host = String(trimmed[trimmed.startIndex..<colon])
        let portText = trimmed[trimmed.index(after: colon)...]
        guard let port = Int(portText), port > 0, port <= 65535, !host.contains(":") else {
            return (trimmed, nil)
        }
        return (host, port)
    }
}

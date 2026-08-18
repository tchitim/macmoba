// Importing connections from the tools people are leaving behind.
//
// Moving into a new client is only worth it if you do not have to retype a
// hundred hosts, so MacMoba reads the three formats that actually travel
// between machines: OpenSSH's `~/.ssh/config` (every SSH user has one), PuTTY's
// exported `.reg` (the Windows way to hand someone your sessions), and RDCMan's
// `.rdg` (a whole tree of RDP servers). Each parser turns text into real
// `SessionConfig`s — the same objects the editor produces — so an imported
// session is indistinguishable from one typed by hand.
//
// Every parser is deliberately forgiving: an unknown key is skipped, not fatal,
// because these files are hand-edited and full of options we do not model.
// Nothing here touches the vault; the caller decides what to keep.

import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// The formats we can read. `detect` sniffs a file so the UI can offer one
/// "Import…" that figures out the rest.
public enum ImportFormat: String, Sendable, CaseIterable {
    case sshConfig
    case putty
    case rdcman

    public var displayName: String {
        switch self {
        case .sshConfig: return "OpenSSH config"
        case .putty: return "PuTTY (.reg)"
        case .rdcman: return "Remote Desktop Manager (.rdg)"
        }
    }
}

public enum SessionImporter {
    /// Best guess at a file's format from its content, so the caller can route
    /// it without asking. Content wins over extension — a `.txt` copy of an ssh
    /// config still imports.
    public static func detect(filename: String, content: String) -> ImportFormat? {
        let lower = filename.lowercased()
        if lower.hasSuffix(".rdg") { return .rdcman }
        if lower.hasSuffix(".reg") { return .putty }

        let head = content.prefix(4096)
        if head.contains("<RDCMan") || head.contains("<version>") && head.contains("<server>") {
            return .rdcman
        }
        if head.contains("SimonTatham\\PuTTY") || head.contains("Windows Registry Editor") {
            return .putty
        }
        // ssh config has no header; recognise it by its keywords at line starts.
        let sshKeys = ["host ", "hostname ", "port ", "identityfile ", "proxyjump ", "user "]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            if sshKeys.contains(where: { line.hasPrefix($0) }) { return .sshConfig }
        }
        return nil
    }

    /// Parse `content` as `format`, returning ready-to-save sessions. SSH is
    /// delegated to the dedicated `SSHConfigImporter` (which also handles
    /// `Include` and dedup); `existing` lets it skip hosts already saved.
    public static func parse(_ content: String, as format: ImportFormat,
                             existing: [SessionConfig] = []) -> [SessionConfig] {
        switch format {
        case .sshConfig:
            let hosts = SSHConfigImporter.parse(text: content)
            return SSHConfigImporter.sessions(from: hosts, existing: existing, group: nil)
        case .putty:
            return dedup(PuTTYImport.parse(content), against: existing)
        case .rdcman:
            return dedup(RDCManImport.parse(content), against: existing)
        }
    }

    /// Drop candidates already present, matched on user+host+port so a second
    /// import of the same file is a no-op. (SSH dedups inside its own importer.)
    private static func dedup(_ candidates: [SessionConfig],
                              against existing: [SessionConfig]) -> [SessionConfig] {
        func key(_ s: SessionConfig) -> String { "\(s.username)@\(s.host):\(s.port)" }
        var seen = Set(existing.map(key))
        var result: [SessionConfig] = []
        for c in candidates where seen.insert(key(c)).inserted {
            result.append(c)
        }
        return result
    }
}

// MARK: - PuTTY exported registry (.reg)

enum PuTTYImport {
    /// PuTTY stores each session under
    /// `[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\NAME]` with
    /// `"HostName"`, `"PortNumber"`, `"Protocol"`, `"UserName"` values. Names
    /// are URL-encoded (spaces become `%20`). We keep ssh/telnet/rlogin(→telnet)
    /// and skip the rest.
    static func parse(_ content: String) -> [SessionConfig] {
        var sessions: [SessionConfig] = []
        var name: String?
        var values: [String: String] = [:]

        func flush() {
            if let n = name, let s = build(name: n, values: values) { sessions.append(s) }
            name = nil
            values = [:]
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                let path = String(line.dropFirst().dropLast())
                if let range = path.range(of: "PuTTY\\Sessions\\") {
                    name = decodePuTTYName(String(path[range.upperBound...]))
                }
                continue
            }
            guard name != nil else { continue }
            if let (key, value) = parseRegValue(line) { values[key] = value }
        }
        flush()
        return sessions
    }

    private static func build(name: String, values: [String: String]) -> SessionConfig? {
        guard let host = values["HostName"], !host.isEmpty else { return nil }
        let proto = (values["Protocol"] ?? "ssh").lowercased()
        let kind: SessionKind
        switch proto {
        case "ssh": kind = .ssh
        case "telnet", "rlogin", "raw": kind = .telnet
        default: return nil   // serial/other PuTTY protocols we do not map from .reg
        }
        let port = values["PortNumber"].flatMap(Int.init) ?? kind.defaultPort
        return SessionConfig(
            name: name,
            host: host,
            port: port,
            username: values["UserName"] ?? "",
            authType: "password",
            kind: kind.rawValue)
    }

    /// `"HostName"="1.2.3.4"` or `"PortNumber"=dword:00000016`.
    private static func parseRegValue(_ line: String) -> (String, String)? {
        guard line.hasPrefix("\""), let eq = line.range(of: "\"=") else { return nil }
        let key = String(line[line.index(after: line.startIndex)..<eq.lowerBound])
        var raw = String(line[eq.upperBound...])
        if raw.hasPrefix("dword:") {
            let hex = String(raw.dropFirst("dword:".count))
            return (key, String(Int(hex, radix: 16) ?? 0))
        }
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            raw = String(raw.dropFirst().dropLast())
        }
        return (key, raw)
    }

    /// PuTTY escapes session names with `%NN`.
    private static func decodePuTTYName(_ encoded: String) -> String {
        var result = ""
        var iter = encoded.startIndex
        while iter < encoded.endIndex {
            let ch = encoded[iter]
            if ch == "%", let next = encoded.index(iter, offsetBy: 3, limitedBy: encoded.endIndex) {
                let hex = encoded[encoded.index(after: iter)..<next]
                if hex.count == 2, let code = UInt8(hex, radix: 16) {
                    result.append(Character(Unicode.Scalar(code)))
                    iter = next
                    continue
                }
            }
            result.append(ch)
            iter = encoded.index(after: iter)
        }
        return result
    }
}

// MARK: - RDCMan .rdg (XML)

enum RDCManImport {
    /// RDCMan stores a tree of `<group>`s and `<server>`s. Each `<server>`
    /// becomes an RDP session; the enclosing groups become our slash-joined
    /// group path so the folder structure survives the import.
    static func parse(_ content: String) -> [SessionConfig] {
        guard let data = content.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = RDGDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.sessions
    }
}

private final class RDGDelegate: NSObject, XMLParserDelegate {
    var sessions: [SessionConfig] = []

    // Group names, innermost last, so the current path is groupStack.joined("/").
    private var groupStack: [String] = []
    private var elementStack: [String] = []
    private var text = ""

    // The server currently being built, and which sub-object we are inside.
    private var server: Server?
    private var pendingGroupName: String?
    private struct Server { var name = ""; var display = ""; var user = ""; var domain = "" }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        elementStack.append(el)
        text = ""
        switch el {
        case "server": server = Server()
        case "group": pendingGroupName = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = elementStack.count >= 2 ? elementStack[elementStack.count - 2] : ""

        switch el {
        case "name":
            // <name> means different things by context: a group's title, a
            // server's host, or (rarely) something else. Route by grandparent.
            if server != nil, parent == "properties" { server?.name = value }
            else if parent == "properties" { pendingGroupName = value }
        case "displayName":
            if server != nil, parent == "properties" { server?.display = value }
            else if parent == "properties", pendingGroupName == nil { pendingGroupName = value }
        case "userName":
            server?.user = value
        case "domain":
            server?.domain = value
        case "properties":
            // A group's <properties> closes before its children; push its name
            // so nested servers get the full path. Servers handle their own.
            if server == nil, elementStack.count >= 2, elementStack[elementStack.count - 2] == "group" {
                groupStack.append(pendingGroupName ?? "")
            }
        case "server":
            if let s = server, !s.name.isEmpty {
                sessions.append(makeSession(s))
            }
            server = nil
        case "group":
            if !groupStack.isEmpty { groupStack.removeLast() }
        default:
            break
        }

        elementStack.removeLast()
        text = ""
    }

    private func makeSession(_ s: Server) -> SessionConfig {
        let name = s.display.isEmpty ? s.name : s.display
        let group = groupStack.filter { !$0.isEmpty }.joined(separator: "/")
        return SessionConfig(
            name: name,
            host: s.name,
            port: 3389,
            username: s.user,
            authType: "password",
            group: group.isEmpty ? nil : group,
            kind: SessionKind.rdp.rawValue,
            domain: s.domain.isEmpty ? nil : s.domain)
    }
}

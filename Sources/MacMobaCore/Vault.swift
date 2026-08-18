// Encrypted credential vault — byte-compatible with the Electron (Node.js)
// version: scrypt (N=16384, r=8, p=1) key derivation + AES-256-GCM.
// File format: {"v":1,"kdf":"scrypt","salt":b64,"iv":b64,"tag":b64,"ct":b64}

import Crypto
import CryptoSwift
import Foundation

/// What protocol a saved session speaks. Stored as a string so an unknown
/// value from a newer build degrades to SSH rather than failing to decode.
public enum SessionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case ssh
    case mosh
    case telnet
    case rlogin
    case ftp
    case web
    case vnc
    case rdp
    case serial

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ssh: return "SSH"
        case .mosh: return "Mosh"
        case .telnet: return "Telnet"
        case .rlogin: return "Rlogin"
        case .ftp: return "FTP"
        case .web: return "Web"
        case .vnc: return "VNC"
        case .rdp: return "RDP"
        case .serial: return "Serial"
        }
    }

    /// SF Symbol for this protocol, used in the sidebar and on tab chips so a
    /// connection's type is readable at a glance.
    public var symbolName: String {
        switch self {
        case .ssh: return "terminal"
        // A terminal that survives losing the network.
        case .mosh: return "terminal.badge.checkmark"
        // Same shape as SSH — it is a terminal — but marked, because the
        // difference that matters is that nothing here is encrypted.
        case .telnet: return "terminal.badge.xmark"
        // Same story as Telnet — a cleartext remote terminal.
        case .rlogin: return "terminal.badge.xmark"
        // A file browser, not a terminal: an FTP session has no shell at all.
        case .ftp: return "folder.badge.gearshape"
        case .web: return "globe"
        case .vnc: return "display"
        case .rdp: return "macwindow.on.rectangle"
        // A physical cable to a device — a terminal, but over a wire.
        case .serial: return "cable.connector"
        }
    }

    /// Whether a username is part of this protocol's identity. Classic VNC
    /// authenticates with a password alone, and Telnet has no authentication
    /// of its own at all — you log in by typing at the remote's own prompt.
    /// A serial line has no login at all.
    public var usesUsername: Bool {
        self == .ssh || self == .mosh || self == .rdp || self == .ftp || self == .rlogin
    }

    public var defaultPort: Int {
        switch self {
        // Mosh bootstraps over SSH, so its port is the SSH one; the UDP port is
        // chosen by mosh-server at connect time and is never configured here.
        case .ssh, .mosh: return 22
        case .telnet: return 23
        // The classic BSD rlogin port.
        case .rlogin: return 513
        // Plain FTP. A session set to implicit TLS is created on 990 instead;
        // see SessionConfig.ftpSecurity.
        case .ftp: return 21
        // Not dialled directly: a web session opens a URL, and the port is
        // part of that.
        case .web: return 80
        case .vnc: return 5900
        case .rdp: return 3389
        // A serial session has no TCP port; the baud rate lives in its own field.
        case .serial: return 9600
        }
    }

    /// Everything except SSH is reached by tunnelling a TCP port through an SSH
    /// session; SSH does its jump-host hop inside the protocol instead. For
    /// Telnet this is the only way to make the hop private, which matters more
    /// there than anywhere else.
    /// FTP is excluded even though it is a plain TCP protocol: passive mode
    /// opens a SECOND connection per transfer, on a port the server picks at
    /// runtime, so one forwarded port is not enough to make it work.
    public var usesPortTunnel: Bool {
        self != .ssh && self != .mosh && self != .ftp && self != .web && self != .serial
    }

    /// A local hardware connection with no network at all — a serial port. It
    /// has no host, no login, and nothing to tunnel or fail over.
    public var isSerial: Bool { self == .serial }

    /// Whether this protocol can live in a split pane. A pane is a terminal —
    /// splitting, broadcast input, SFTP, session logging and search all assume
    /// one. VNC and RDP own a whole tab instead, so they cannot be split into
    /// or merged in. Telnet is a terminal, so it does.
    public var fitsInSplitPane: Bool {
        self == .ssh || self == .telnet || self == .mosh || self == .rlogin
    }

    /// True when the protocol sends everything, passwords included, in clear
    /// text. Telnet predates the assumption that networks are hostile.
    /// Plain FTP is as exposed as Telnet: USER and PASS cross the network in
    /// clear text. A session using implicit TLS is not, which is why the
    /// warning shown to the user reads `SessionConfig.sendsCredentialsInClear`
    /// rather than this.
    public var isUnencrypted: Bool { self == .telnet || self == .ftp || self == .rlogin }

    /// True when this session is a file browser rather than a terminal or a
    /// screen — no pane tree, no logging, no search.
    public var isFileBrowser: Bool { self == .ftp }

    /// A web page rather than a connection: no username, no password, and its
    /// "via" session is a SOCKS proxy rather than a forwarded port.
    public var isWeb: Bool { self == .web }

    /// True when logging in means an SSH login, so the session needs a username
    /// and the full set of SSH credentials — including a private key.
    ///
    /// Mosh belongs here even though the session itself is UDP: it starts by
    /// running mosh-server over SSH, so it authenticates exactly like SSH does.
    /// Missing that meant a Mosh session could only ever use a password, which
    /// rules out anyone who logs in with a key.
    public var authenticatesOverSSH: Bool { self == .ssh || self == .mosh }

    /// True when a jump host is reached by SSH's own hop rather than by
    /// forwarding a TCP port.
    public var usesJumpHost: Bool { authenticatesOverSSH }
}

public struct SessionConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authType: String // "password" | "keyfile" | "keytext" | "agent"
    public var password: String?
    public var keyPath: String?
    public var keyData: String?
    public var passphrase: String?
    /// Sidebar folder/project this session belongs to. Optional so older
    /// vault.json files (and the Electron version) stay compatible.
    public var group: String?
    /// id of another SSH session to reach this one through.
    /// For an SSH session that is ProxyJump (`ssh -J`); for a VNC or RDP
    /// session it is the SSH session whose direct-tcpip channel carries the
    /// connection. Same meaning either way: "get there via that host".
    /// The referenced session may itself have a `proxyJump`, forming a chain
    /// (ssh -J b,a) — see JumpChain.
    public var proxyJump: String?
    /// Alternative addresses to try if the primary host is unreachable, each
    /// "host" or "host:port". Gateway failover: a bastion with a standby, or a
    /// service with more than one entry point. Optional, back-compat.
    public var fallbackHosts: [String]?
    /// "ssh" (default), "telnet", "vnc" or "rdp". Optional so vaults written
    /// before these existed — and the Electron version — still decode.
    public var kind: String?
    /// Windows domain for RDP. AD servers usually need this; it can also be
    /// given inline as DOMAIN\\user in the username field.
    public var domain: String?
    /// RDP security layer: "negotiate" (default), "nla", "tls" or "rdp".
    /// Worth exposing because a server that refuses the negotiated choice
    /// simply drops the connection, which looks like a network fault.
    public var rdpSecurity: String?
    /// Local folders to mount inside the RDP session as drives.
    /// Optional, so vaults written before this existed still decode.
    public var sharedFolders: [String]?
    /// "fitWindow" (default) or "fixed". See `RDPDisplayMode`.
    public var rdpDisplayMode: String?
    /// Desktop size for `.fixed`, in pixels. Ignored when fitting the window.
    public var rdpWidth: Int?
    public var rdpHeight: Int?
    /// Span every attached display. Only takes effect in full screen, because
    /// that is the only time the session actually owns all the screens.
    public var rdpUseAllDisplays: Bool?
    /// "plain" or "implicitTLS" for an FTP session. Optional so vaults written
    /// before FTP existed still decode.
    public var ftpTLS: String?
    /// The page a web session opens.
    public var webURL: String?
    /// RDP "alternate shell": a program to run instead of the desktop shell.
    /// Carried over from .rdp files, where CyberArk PSM puts its routing
    /// ("psm /u user /a target /c component").
    public var rdpAlternateShell: String?
    /// How this session gets its login: `nil`/""/"custom" means the inline
    /// fields on the session itself; a credential id means "use that shared
    /// credential"; "inherit" means "use the group's default credential".
    /// See CredentialResolver. Optional so older/Electron vaults still decode.
    public var credentialRef: String?
    /// Free-form notes shown in the editor and searchable in the sidebar.
    public var notes: String?
    /// A colour swatch for the sidebar row — a `SessionColor` rawValue, or nil
    /// for the default tint. Purely organisational.
    public var color: String?
    /// Labels for grouping across folders and filtering the sidebar. Optional
    /// so older/Electron vaults still decode.
    public var tags: [String]?
    /// Commands typed into the shell automatically once a terminal session
    /// connects — a startup script (cd somewhere, tail a log, attach tmux).
    /// One command per line. Terminal kinds only; optional for back-compat.
    public var onConnectCommands: String?
    /// Baud rate for a serial session (the device path lives in `host`). Default
    /// 9600 when absent. Optional, back-compat.
    public var serialBaud: Int?
    /// Serial line format as "8N1" (data bits / parity N|E|O / stop bits).
    /// Default "8N1"; see SerialSettings.
    public var serialFormat: String?
    /// Expect/send steps run after connect: wait for a prompt, then type. Runs
    /// after `onConnectCommands`. Optional, back-compat. See ExpectMachine.
    public var expectSequence: [ExpectStep]?
    /// Tunnel the Mac's X server to this session so remote GUI apps display
    /// locally (via a remote forward; needs XQuartz). Optional, back-compat.
    public var x11Forwarding: Bool?

    /// The serial line settings for a serial session, parsed with sensible
    /// defaults (9600 8N1).
    public var serialSettings: SerialSettings {
        SerialSettings(baud: serialBaud ?? 9600, format: serialFormat)
    }

    /// The chosen swatch, falling back to `.none` for unknown/absent values —
    /// the same forgiving decode as `sessionKind`.
    public var colorTag: SessionColor {
        SessionColor(rawValue: color ?? "") ?? .none
    }

    public var sessionKind: SessionKind {
        SessionKind(rawValue: kind ?? "") ?? .ssh
    }

    /// How an FTP session is protected. Unknown values fall back to plain
    /// rather than failing to decode, matching how `sessionKind` behaves.
    public var ftpSecurity: FTPSecurity {
        FTPSecurity(rawValue: ftpTLS ?? "") ?? .plain
    }

    /// True when connecting will put this session's password on the network in
    /// clear text. Kind alone is not enough: an FTP session using TLS does not.
    public var sendsCredentialsInClear: Bool {
        switch sessionKind {
        case .telnet: return true
        case .ftp: return ftpSecurity == .plain
        default: return false
        }
    }

    public var displayMode: RDPDisplayMode {
        RDPDisplayMode(rawValue: rdpDisplayMode ?? "") ?? .fitWindow
    }

    /// The desktop to ask for when `displayMode` is `.fixed`, clamped to
    /// something a server will accept. Nil for `.fitWindow`, where the pane
    /// decides instead.
    public var fixedDesktopSize: (width: Int, height: Int)? {
        guard displayMode == .fixed else { return nil }
        let width = max(RDPDesktopSize.minimumWidth, rdpWidth ?? 1920) & ~3
        let height = max(RDPDesktopSize.minimumHeight, rdpHeight ?? 1080)
        return (width, height)
    }

    public init(id: String = UUID().uuidString, name: String, host: String, port: Int = 22,
                username: String, authType: String = "password", password: String? = nil,
                keyPath: String? = nil, keyData: String? = nil, passphrase: String? = nil,
                group: String? = nil, proxyJump: String? = nil,
                kind: String? = nil, domain: String? = nil,
                rdpSecurity: String? = nil, sharedFolders: [String]? = nil,
                rdpDisplayMode: String? = nil, rdpWidth: Int? = nil,
                rdpHeight: Int? = nil, ftpTLS: String? = nil, webURL: String? = nil,
                rdpUseAllDisplays: Bool? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.password = password
        self.keyPath = keyPath
        self.keyData = keyData
        self.passphrase = passphrase
        self.group = group
        self.proxyJump = proxyJump
        self.kind = kind
        self.domain = domain
        self.rdpSecurity = rdpSecurity
        self.sharedFolders = sharedFolders
        self.rdpDisplayMode = rdpDisplayMode
        self.rdpWidth = rdpWidth
        self.rdpHeight = rdpHeight
        self.ftpTLS = ftpTLS
        self.webURL = webURL
        self.rdpUseAllDisplays = rdpUseAllDisplays
    }

    /// Spanning displays only makes sense while following the window: a fixed
    /// desktop size is by definition one rectangle.
    public var usesAllDisplays: Bool {
        (rdpUseAllDisplays ?? false) && displayMode == .fitWindow
    }

    /// Drive-redirection arguments in FreeRDP's "name,path" form. The name is
    /// what shows up in Explorer, so it is the folder's own name with anything
    /// awkward stripped rather than a bare letter.
    public var driveRedirections: [String] {
        (sharedFolders ?? []).compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let name = (trimmed as NSString).lastPathComponent
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "\\", with: " ")
            return "\(name.isEmpty ? "Mac" : name),\(trimmed)"
        }
    }
}

/// How big a desktop to ask an RDP server for.
public enum RDPDisplayMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Follow the pane, re-asking the server whenever it changes size.
    case fitWindow
    /// Ask for one fixed size and letterbox it. What you want when the desktop
    /// has to stay a known shape — screenshots, an app laid out for a
    /// particular resolution, or a server whose dynamic resizing misbehaves.
    case fixed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fitWindow: return "Fit to window"
        case .fixed: return "Fixed size"
        }
    }

    public var detail: String {
        switch self {
        case .fitWindow:
            return "Resize the remote desktop to match the pane. Needs a server "
                 + "that supports display control (Windows 8.1 / Server 2012 R2 and later)."
        case .fixed:
            return "Always use the same desktop size, scaled to fit the pane."
        }
    }
}

public enum RDPSecurity: String, Codable, Sendable, CaseIterable, Identifiable {
    case negotiate
    case nla
    case tls
    case rdp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .negotiate: return "Negotiate"
        case .nla: return "NLA"
        case .tls: return "TLS"
        case .rdp: return "RDP (legacy)"
        }
    }

    public var detail: String {
        switch self {
        case .negotiate: return "Let the server choose. Right for almost everything."
        case .nla: return "Force Network Level Authentication — what modern Windows expects."
        case .tls: return "TLS without NLA, for servers with NLA turned off."
        case .rdp: return "Legacy RDP encryption, for very old servers."
        }
    }
}

public struct TunnelConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var type: String // "local" | "remote"
    public var sessionId: String
    public var bindHost: String
    public var bindPort: Int
    public var targetHost: String
    public var targetPort: Int

    public init(id: String = UUID().uuidString, name: String, type: String, sessionId: String,
                bindHost: String = "127.0.0.1", bindPort: Int, targetHost: String, targetPort: Int) {
        self.id = id
        self.name = name
        self.type = type
        self.sessionId = sessionId
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }
}

/// A saved command snippet — MobaXterm's macro. Kept in the vault rather than
/// UserDefaults because the commands people save tend to include hostnames,
/// paths and occasionally credentials.
public struct MacroConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// What to type. May be several lines; each becomes its own command.
    public var command: String
    /// Press Return at the end, i.e. run it rather than leave it on the prompt.
    public var sendReturn: Bool

    public init(id: String = UUID().uuidString, name: String, command: String,
                sendReturn: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.sendReturn = sendReturn
    }

    /// The exact characters to write to the PTY. A terminal expects CR for
    /// Return — sending LF would land mid-line in most shells — so every line
    /// break is normalised to CR, and the trailing Return is only added when
    /// the text does not already end in one.
    public var keystrokes: String {
        var text = command
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        if sendReturn, !text.hasSuffix("\r") { text += "\r" }
        return text
    }
}

/// A reusable login, shared by many sessions.
///
/// The reason this exists: without it, every session carries its own copy of a
/// username and password, so changing a password that ten hosts share means
/// editing ten sessions. A credential object is edited once and referenced by
/// `SessionConfig.credentialRef`.
///
/// It holds exactly the fields that make up a login and nothing about where to
/// connect — a credential is "who you are", a session is "where you go".
public struct CredentialConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var username: String
    /// "password" | "keyfile" | "keytext" | "agent" — same vocabulary as
    /// SessionConfig.authType, because a resolved credential simply supplies
    /// these fields to the session.
    public var authType: String
    public var password: String?
    public var keyPath: String?
    public var keyData: String?
    public var passphrase: String?
    /// Windows domain, for credentials used by RDP sessions.
    public var domain: String?

    public init(id: String = UUID().uuidString, name: String, username: String,
                authType: String = "password", password: String? = nil,
                keyPath: String? = nil, keyData: String? = nil,
                passphrase: String? = nil, domain: String? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.authType = authType
        self.password = password
        self.keyPath = keyPath
        self.keyData = keyData
        self.passphrase = passphrase
        self.domain = domain
    }
}

public struct VaultData: Codable, Equatable, Sendable {
    public var sessions: [SessionConfig]
    public var tunnels: [TunnelConfig]
    public var macros: [MacroConfig]
    /// Shared login objects, referenced by `SessionConfig.credentialRef`.
    public var credentials: [CredentialConfig]
    /// A group's default credential: group name -> credential id. A session
    /// whose `credentialRef` is "inherit" uses the entry for its own group.
    public var groupCredentials: [String: String]
    /// Reusable session blueprints. A template is an ordinary SessionConfig
    /// (its host may be blank) that "New from template" copies into a real
    /// session. Kept separate from `sessions` so it never appears in the connect
    /// list. Optional so older vaults still decode.
    public var templates: [SessionConfig]
    /// Folders that exist in their own right, as slash paths ("Production/Linux").
    ///
    /// Most folders are implied by the sessions inside them, and those need no
    /// entry here. This list is what lets a folder exist while EMPTY — created
    /// from "New Subfolder…" and filled afterwards — which a purely derived
    /// tree cannot express. Optional so older vaults still decode.
    public var folders: [String]

    public init(sessions: [SessionConfig] = [], tunnels: [TunnelConfig] = [],
                macros: [MacroConfig] = [], credentials: [CredentialConfig] = [],
                groupCredentials: [String: String] = [:],
                templates: [SessionConfig] = [],
                folders: [String] = []) {
        self.sessions = sessions
        self.tunnels = tunnels
        self.macros = macros
        self.credentials = credentials
        self.groupCredentials = groupCredentials
        self.templates = templates
        self.folders = folders
    }

    // Hand-written so a vault saved before macros/credentials existed — or one
    // written by the Electron version, which does not know the key — still
    // decodes. Synthesised Codable would throw on the missing key instead.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([SessionConfig].self, forKey: .sessions) ?? []
        tunnels = try container.decodeIfPresent([TunnelConfig].self, forKey: .tunnels) ?? []
        macros = try container.decodeIfPresent([MacroConfig].self, forKey: .macros) ?? []
        credentials = try container.decodeIfPresent([CredentialConfig].self,
                                                    forKey: .credentials) ?? []
        groupCredentials = try container.decodeIfPresent([String: String].self,
                                                         forKey: .groupCredentials) ?? [:]
        templates = try container.decodeIfPresent([SessionConfig].self,
                                                  forKey: .templates) ?? []
        folders = try container.decodeIfPresent([String].self, forKey: .folders) ?? []
    }
}

public enum VaultError: Error, Equatable {
    case alreadyExists
    case notFound
    case locked
    case wrongPassword
    case corrupt(String)
    case weakPassword
}

public final class Vault {
    private struct FileFormat: Codable {
        var v: Int
        var kdf: String
        var salt: String
        var iv: String
        var tag: String
        var ct: String
    }

    public let fileURL: URL
    private var key: SymmetricKey?
    private var salt: Data?
    private var data: VaultData?

    private static let scryptN = 16384
    private static let scryptR = 8
    private static let scryptP = 1

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public enum Status { case none, locked, unlocked }

    public var status: Status {
        if key != nil { return .unlocked }
        return FileManager.default.fileExists(atPath: fileURL.path) ? .locked : .none
    }

    @discardableResult
    public func create(masterPassword: String) throws -> VaultData {
        guard status == .none else { throw VaultError.alreadyExists }
        guard masterPassword.count >= 4 else { throw VaultError.weakPassword }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        self.key = try Self.deriveKey(password: masterPassword, salt: salt)
        self.salt = salt
        self.data = VaultData()
        try writeEncrypted()
        return self.data!
    }

    @discardableResult
    public func unlock(masterPassword: String) throws -> VaultData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw VaultError.notFound }
        let raw = try Data(contentsOf: fileURL)
        let file = try JSONDecoder().decode(FileFormat.self, from: raw)
        guard file.kdf == "scrypt",
              let salt = Data(base64Encoded: file.salt),
              let iv = Data(base64Encoded: file.iv),
              let tag = Data(base64Encoded: file.tag),
              let ct = Data(base64Encoded: file.ct) else {
            throw VaultError.corrupt("bad base64 or unknown kdf")
        }
        let key = try Self.deriveKey(password: masterPassword, salt: salt)
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: ct,
            tag: tag
        )
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            throw VaultError.wrongPassword
        }
        let decoded = try JSONDecoder().decode(VaultData.self, from: plaintext)
        self.key = key
        self.salt = salt
        self.data = decoded
        return decoded
    }

    public func save(_ newData: VaultData) throws {
        guard key != nil else { throw VaultError.locked }
        self.data = newData
        try writeEncrypted()
    }

    public func getData() throws -> VaultData {
        guard let d = data else { throw VaultError.locked }
        return d
    }

    public func lock() {
        key = nil
        data = nil
        salt = nil
    }

    // MARK: - Internals

    static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let derived = try Scrypt(
            password: Array(password.utf8),
            salt: Array(salt),
            dkLen: 32,
            N: scryptN,
            r: scryptR,
            p: scryptP
        ).calculate()
        return SymmetricKey(data: Data(derived))
    }

    private func writeEncrypted() throws {
        guard let key, let salt, let data else { throw VaultError.locked }
        let plaintext = try JSONEncoder().encode(data)
        let nonce = AES.GCM.Nonce() // 12 bytes, matches Node's randomBytes(12)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        let file = FileFormat(
            v: 1,
            kdf: "scrypt",
            salt: salt.base64EncodedString(),
            iv: Data(nonce).base64EncodedString(),
            tag: sealed.tag.base64EncodedString(),
            ct: sealed.ciphertext.base64EncodedString()
        )
        let out = try JSONEncoder().encode(file)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp")
        try out.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tmp, to: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

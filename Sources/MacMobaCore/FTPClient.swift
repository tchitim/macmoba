// An FTP client (RFC 959) for the file browser.
//
// Two connections, as FTP has always worked: a long-lived control connection
// carrying commands and replies as text, and a fresh data connection for each
// transfer or listing. Only PASSIVE mode is used — the client opens the data
// connection — because active mode asks the server to connect back to this
// Mac, which no home router or firewall has allowed for twenty years.
//
// An actor, because FTP is strictly one command at a time: two overlapping
// commands on the control connection do not interleave, they corrupt it.

import Foundation
import Network

public enum FTPError: Error, LocalizedError, Equatable {
    case connectionFailed(String)
    case authenticationFailed(String)
    /// The server answered, and said no.
    case server(code: Int, message: String)
    case protocolError(String)
    case localFile(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail): return "Could not connect: \(detail)"
        case .authenticationFailed(let detail): return "Login failed: \(detail)"
        case .server(let code, let message): return "Server said \(code): \(message)"
        case .protocolError(let detail): return "Unexpected reply: \(detail)"
        case .localFile(let detail): return detail
        case .unsupported(let detail): return detail
        }
    }
}

/// How the connection is protected.
public enum FTPSecurity: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Everything in clear text, credentials included.
    case plain
    /// TLS from the first byte, the whole session (port 990 by convention).
    case implicitTLS

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plain: return "None (plain FTP)"
        case .implicitTLS: return "Implicit TLS (FTPS)"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .plain: return 21
        case .implicitTLS: return 990
        }
    }
}

// MARK: - Byte stream

/// The transport under the protocol.
///
/// Separated so the FTP logic never touches a socket API directly — and so
/// that adding a stream which can start in the clear and turn on TLS later
/// (explicit `AUTH TLS`) is a matter of another conformance rather than a
/// rewrite. Network.framework cannot do that upgrade, which is why explicit
/// FTPS is not offered yet.
protocol FTPStream: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    /// Next chunk, or nil at end of stream.
    func receive() async throws -> Data?
    func cancel()
}

/// Lets exactly one caller through.
///
/// `NWConnection`'s state handler fires repeatedly — ready then failed, or
/// failed then cancelled — and resuming a continuation twice is a crash rather
/// than a warning.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// An `NWConnection`, wrapped so it can be awaited.
final class NWStream: FTPStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.macmoba.ftp")
    private let stateLock = NSLock()
    /// Set when a receive came back with `isComplete`. The flag can arrive
    /// ALONGSIDE the last chunk of data rather than on its own — and asking
    /// for more after that fails with "No message available on STREAM", which
    /// surfaced as a listing that randomly failed instead of ending.
    private var finished = false

    init(host: String, port: Int, tls: Bool) {
        let parameters: NWParameters
        if tls {
            parameters = .tls
        } else {
            parameters = .tcp
        }
        // Nagle off: FTP is a chatty request/response protocol where every
        // command is tiny, and waiting to coalesce them just adds latency.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 15
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // A state handler can fire more than once — ready then failed, or
            // failed then cancelled — and resuming a continuation twice is a
            // crash, not a warning. Guarded by the connection's own queue,
            // which is the only thread the handler runs on.
            let once = ResumeOnce()
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                guard once.claim() else { return }
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(FTPError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    finish(.failure(FTPError.connectionFailed("cancelled")))
                case .waiting(let error):
                    // "Waiting" means it will retry forever — for a file
                    // browser that is a failure, not patience.
                    finish(.failure(FTPError.connectionFailed(error.localizedDescription)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: FTPError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> Data? {
        stateLock.lock()
        let alreadyFinished = finished
        stateLock.unlock()
        if alreadyFinished { return nil }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [self] data, _, isComplete, error in
                if isComplete {
                    stateLock.lock()
                    finished = true
                    stateLock.unlock()
                }
                if let error {
                    continuation.resume(
                        throwing: FTPError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    // Returned even when isComplete came with it; the flag is
                    // remembered above so the next call ends the loop without
                    // touching the closed connection.
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

// MARK: - Client

public actor FTPClient {
    private let control: FTPStream
    private let host: String
    private let useTLS: Bool
    /// Bytes read from the control connection but not yet consumed as a reply.
    private var pending = Data()
    /// What the server said it supports, from FEAT.
    private var features: Set<String> = []
    private var closed = false

    /// 64 KB matches what Network.framework hands over in one receive.
    private static let chunkSize = 64 * 1024

    private init(control: FTPStream, host: String, useTLS: Bool) {
        self.control = control
        self.host = host
        self.useTLS = useTLS
    }

    public static func connect(config: SessionConfig) async throws -> FTPClient {
        // A jump host would need a forwarded port for the control connection
        // AND another for every data connection, on ports the server picks at
        // runtime. Rather than appear to work and then stall on the first
        // listing, it is refused.
        if let jump = config.proxyJump, !jump.isEmpty {
            throw FTPError.unsupported(
                "FTP through a jump host is not supported — passive mode needs a new "
                + "connection on a port the server chooses for each transfer. Use SFTP.")
        }
        let security = config.ftpSecurity
        let port = config.port > 0 ? config.port : security.defaultPort
        let stream = NWStream(host: config.host, port: port, tls: security == .implicitTLS)
        let client = FTPClient(control: stream, host: config.host,
                               useTLS: security == .implicitTLS)
        do {
            try await stream.start()
            try await client.login(config: config)
            return client
        } catch {
            stream.cancel()
            throw error
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        // Best effort: the socket is going away regardless, so QUIT is sent
        // without waiting for the 221.
        Task { try? await self.sendCommand("QUIT") }
        control.cancel()
    }

    // MARK: - Control connection

    private func login(config: SessionConfig) async throws {
        let greeting = try await readReply()
        guard greeting.isPositive else {
            throw FTPError.connectionFailed(greeting.text)
        }

        let user = config.username.isEmpty ? "anonymous" : config.username
        let userReply = try await sendCommand("USER \(user)")
        if userReply.code == 331 || userReply.code == 332 {
            // Anonymous servers conventionally want an e-mail address, and
            // reject an empty password outright.
            let password = config.password?.isEmpty == false
                ? config.password!
                : (config.username.isEmpty ? "anonymous@" : "")
            let passReply = try await sendCommand("PASS \(password)")
            guard passReply.isPositive else {
                throw FTPError.authenticationFailed(passReply.text)
            }
        } else if !userReply.isPositive {
            throw FTPError.authenticationFailed(userReply.text)
        }

        // Ask what the server can do. A server that does not know FEAT just
        // says 500, which is fine — everything below has a fallback.
        if let featReply = try? await sendCommand("FEAT"), featReply.isPositive {
            features = FTPProtocol.parseFEAT(featReply.text)
        }
        // Names are bytes on the wire; without this a server may mangle
        // anything outside ASCII.
        if features.contains("UTF8") {
            _ = try? await sendCommand("OPTS UTF8 ON")
        }
        // Binary. The default is ASCII, which silently rewrites line endings
        // and corrupts every file that is not text.
        let type = try await sendCommand("TYPE I")
        guard type.isPositive else { throw FTPError.protocolError(type.text) }
    }

    @discardableResult
    private func sendCommand(_ command: String) async throws -> FTPProtocol.Reply {
        guard let data = (command + "\r\n").data(using: .utf8) else {
            throw FTPError.protocolError("cannot encode \(command)")
        }
        try await control.send(data)
        return try await readReply()
    }

    /// Read until a whole reply has arrived — however many lines that takes.
    private func readReply() async throws -> FTPProtocol.Reply {
        while true {
            if let reply = takeReply() { return reply }
            guard let chunk = try await control.receive() else {
                throw FTPError.connectionFailed("the server closed the connection")
            }
            pending.append(chunk)
        }
    }

    /// Pull one complete reply out of `pending`, leaving anything after it.
    private func takeReply() -> FTPProtocol.Reply? {
        guard let text = String(data: pending, encoding: .utf8)
                ?? String(data: pending, encoding: .isoLatin1) else { return nil }
        var lines: [String] = []
        var consumed = 0
        for line in text.components(separatedBy: "\n").dropLast() {
            lines.append(line.hasSuffix("\r") ? String(line.dropLast()) : line)
            consumed += line.utf8.count + 1
            if let reply = FTPProtocol.parseReply(lines) {
                pending.removeFirst(min(consumed, pending.count))
                return reply
            }
        }
        return nil
    }

    private func expect(_ command: String) async throws {
        let reply = try await sendCommand(command)
        guard reply.isPositive else {
            throw FTPError.server(code: reply.code, message: reply.text)
        }
    }

    // MARK: - Data connections

    /// Open the data connection for the next transfer.
    ///
    /// EPSV first: the server returns only a port, so the data connection goes
    /// to the same address as the control one. That is what survives NAT, and
    /// it is the only form defined for IPv6. PASV is the fallback, and its
    /// address is deliberately IGNORED in favour of the control connection's
    /// host — servers behind NAT routinely advertise their private address
    /// there, which would send the transfer to a machine on our own network.
    private func openDataConnection() async throws -> FTPStream {
        var dataPort: Int?
        if let epsv = try? await sendCommand("EPSV"), epsv.isPositive {
            dataPort = FTPProtocol.parseEPSV(epsv.text)
        }
        if dataPort == nil {
            let pasv = try await sendCommand("PASV")
            guard pasv.isPositive, let parsed = FTPProtocol.parsePASV(pasv.text) else {
                throw FTPError.protocolError("no passive port in: \(pasv.text)")
            }
            dataPort = parsed.port
        }
        guard let port = dataPort else {
            throw FTPError.protocolError("no passive port")
        }
        let stream = NWStream(host: host, port: port, tls: useTLS)
        do {
            try await stream.start()
        } catch {
            stream.cancel()
            throw error
        }
        return stream
    }

    /// Run a command whose payload arrives on a data connection.
    ///
    /// The order matters: the data connection is opened first, then the
    /// command is sent, then the payload is read, and only then is the final
    /// reply collected. Reading the reply before draining the data connection
    /// deadlocks against servers that finish writing before they answer.
    private func withDataConnection<T>(
        _ command: String,
        _ body: (FTPStream) async throws -> T
    ) async throws -> T {
        let data = try await openDataConnection()
        defer { data.cancel() }

        let opening = try await sendCommand(command)
        guard opening.isPreliminary || opening.isPositive else {
            throw FTPError.server(code: opening.code, message: opening.text)
        }
        let result = try await body(data)
        // 226/250 closes the transfer. A 4xx/5xx here means the payload was
        // incomplete even though bytes arrived, so it must not be swallowed.
        if opening.isPreliminary {
            let done = try await readReply()
            guard done.isPositive else {
                throw FTPError.server(code: done.code, message: done.text)
            }
        }
        return result
    }

    private func readAll(_ stream: FTPStream) async throws -> Data {
        var buffer = Data()
        while let chunk = try await stream.receive() {
            try Task.checkCancellation()
            buffer.append(chunk)
        }
        return buffer
    }

    // MARK: - Operations

    public func realpath(_ path: String) async throws -> String {
        if path != "." && path != "" {
            try await expect("CWD \(path)")
        }
        let reply = try await sendCommand("PWD")
        guard reply.isPositive else {
            throw FTPError.server(code: reply.code, message: reply.text)
        }
        // 257 "/home/user" is the current directory — the path is quoted, and
        // a literal quote inside it is doubled.
        guard let open = reply.text.firstIndex(of: "\"") else {
            return reply.text.trimmingCharacters(in: .whitespaces)
        }
        let rest = reply.text[reply.text.index(after: open)...]
        guard let close = rest.lastIndex(of: "\"") else { return String(rest) }
        return String(rest[rest.startIndex..<close]).replacingOccurrences(of: "\"\"", with: "\"")
    }

    public func list(_ path: String) async throws -> [SFTPItem] {
        try await expect("CWD \(path)")
        // MLSD is machine-readable and unambiguous; LIST is whatever the
        // server's `ls` prints, and is only used when MLSD is absent.
        let useMLSD = features.contains("MLSD")
        let command = useMLSD ? "MLSD" : "LIST -a"
        do {
            let raw = try await withDataConnection(command) { try await self.readAll($0) }
            let text = String(data: raw, encoding: .utf8)
                ?? String(data: raw, encoding: .isoLatin1) ?? ""
            return FTPProtocol.parseListing(text, isMLSD: useMLSD)
        } catch let error as FTPError {
            // Some servers reject the "-a" and answer 5xx; retry bare.
            guard case .server = error, !useMLSD else { throw error }
            let raw = try await withDataConnection("LIST") { try await self.readAll($0) }
            let text = String(data: raw, encoding: .utf8)
                ?? String(data: raw, encoding: .isoLatin1) ?? ""
            return FTPProtocol.parseListing(text, isMLSD: false)
        }
    }

    public func mkdir(_ path: String) async throws {
        try await expect("MKD \(path)")
    }

    public func removeFile(_ path: String) async throws {
        try await expect("DELE \(path)")
    }

    public func removeDirectory(_ path: String) async throws {
        try await expect("RMD \(path)")
    }

    public func removeDirectoryRecursively(_ path: String) async throws {
        // Depth first: a directory cannot be removed until it is empty.
        for item in try await list(path) {
            let child = FTPProtocol.join(path, item.name)
            if item.isDirectory {
                try await removeDirectoryRecursively(child)
            } else {
                try await removeFile(child)
            }
        }
        try await removeDirectory(path)
    }

    public func rename(_ oldPath: String, to newPath: String) async throws {
        let from = try await sendCommand("RNFR \(oldPath)")
        // 350 "go ahead" is the only reply that may be followed by RNTO.
        guard from.code == 350 else {
            throw FTPError.server(code: from.code, message: from.text)
        }
        try await expect("RNTO \(newPath)")
    }

    public func size(_ path: String) async throws -> UInt64? {
        let reply = try await sendCommand("SIZE \(path)")
        guard reply.code == 213 else { return nil }
        return UInt64(reply.text.trimmingCharacters(in: .whitespaces))
    }

    public func download(
        remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        let total = try? await size(remotePath)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: localURL.path) else {
            throw FTPError.localFile("cannot write \(localURL.path)")
        }
        defer { try? file.close() }

        var written: UInt64 = 0
        try await withDataConnection("RETR \(remotePath)") { stream in
            while let chunk = try await stream.receive() {
                try Task.checkCancellation()
                if chunk.isEmpty { continue }
                try file.write(contentsOf: chunk)
                written += UInt64(chunk.count)
                progress?(written, total ?? nil)
            }
        }
    }

    public func upload(
        localURL: URL,
        to remotePath: String,
        progress: (@Sendable (UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        guard let file = FileHandle(forReadingAtPath: localURL.path) else {
            throw FTPError.localFile("cannot read \(localURL.path)")
        }
        defer { try? file.close() }
        let total = (try? FileManager.default
            .attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? nil

        var sent: UInt64 = 0
        try await withDataConnection("STOR \(remotePath)") { stream in
            while true {
                try Task.checkCancellation()
                let chunk = try file.read(upToCount: Self.chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try await stream.send(chunk)
                sent += UInt64(chunk.count)
                progress?(sent, total)
            }
            // The transfer ends when the data connection closes, so it has to
            // be closed BEFORE the completion reply is read — otherwise both
            // sides wait for the other.
            stream.cancel()
        }
    }

    // MARK: - Recursive transfers

    public func downloadDirectory(
        remotePath: String,
        to localURL: URL,
        progress: (@Sendable (String, UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        for item in try await list(remotePath) {
            try Task.checkCancellation()
            guard !item.isSymlink else { continue }
            let remote = FTPProtocol.join(remotePath, item.name)
            let local = localURL.appendingPathComponent(item.name)
            if item.isDirectory {
                try await downloadDirectory(remotePath: remote, to: local) { name, done, total in
                    progress?(name, done, total)
                }
            } else {
                try await download(remotePath: remote, to: local) { done, total in
                    progress?(item.name, done, total)
                }
            }
        }
    }

    public func uploadDirectory(
        localURL: URL,
        to remotePath: String,
        progress: (@Sendable (String, UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        // Already there is not an error: uploading into an existing folder is
        // the normal case when a transfer is repeated.
        _ = try? await mkdir(remotePath)
        let contents = try FileManager.default.contentsOfDirectory(
            at: localURL, includingPropertiesForKeys: [.isDirectoryKey])
        for url in contents {
            try Task.checkCancellation()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            let remote = FTPProtocol.join(remotePath, url.lastPathComponent)
            if isDirectory {
                try await uploadDirectory(localURL: url, to: remote) { name, done, total in
                    progress?(name, done, total)
                }
            } else {
                try await upload(localURL: url, to: remote) { done, total in
                    progress?(url.lastPathComponent, done, total)
                }
            }
        }
    }
}

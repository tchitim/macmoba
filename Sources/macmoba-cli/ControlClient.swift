// The Unix-socket client, shared between the one-shot commands and `mcp`.
//
// Extracted from main.swift when `mcp` arrived: the one-shot path wants to
// print-and-exit, the MCP loop wants an error it can put in a JSON-RPC reply
// and keep serving. So this throws, and each caller decides what dying means.

import Darwin
import Foundation

struct ControlResponse: Decodable {
    let ok: Bool
    let data: String?
    let error: String?
}

struct ControlClientError: Error {
    let message: String
}

enum ControlClient {
    /// One request, one JSON line each way, connection per call.
    ///
    /// Connection-per-call is deliberate: the socket is local, the app answers
    /// in microseconds, and a held connection is one more thing to reconnect
    /// when the app restarts between two tool calls.
    static func call(cmd: String, args: [String: String],
                     socketPath: String, tokenPath: String) throws -> ControlResponse {
        guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ControlClientError(
                message: "no control token at \(tokenPath) — is MacMoba running?")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlClientError(message: "socket: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fits = socketPath.withCString { pathBytes -> Bool in
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
            guard strlen(pathBytes) <= maxLen else { return false }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                _ = strcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), pathBytes)
            }
            return true
        }
        guard fits else {
            throw ControlClientError(message: "socket path too long: \(socketPath)")
        }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw ControlClientError(
                message: "cannot reach MacMoba at \(socketPath) — is the app running?")
        }

        struct Request: Encodable {
            let token: String
            let cmd: String
            let args: [String: String]
        }
        var line = try! JSONEncoder().encode(Request(token: token, cmd: cmd, args: args))
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !responseData.contains(0x0A) {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[0..<n])
        }
        guard let newline = responseData.firstIndex(of: 0x0A) else {
            throw ControlClientError(message: "no response from MacMoba")
        }
        guard let response = try? JSONDecoder()
                .decode(ControlResponse.self, from: responseData[..<newline]) else {
            throw ControlClientError(message: "unparseable response: "
                + String(decoding: responseData[..<newline], as: UTF8.self))
        }
        return response
    }
}

// `macmoba` — drive a running MacMoba from the shell (or from an agent that
// SSHes back to this Mac): list tabs, type into one, read its screen, raise a
// notification. Speaks one JSON line over the app's Unix control socket; the
// token beside the socket authenticates this user.
//
// Usage:
//   macmoba ping
//   macmoba list-tabs
//   macmoba open <session-name>
//   macmoba open-url <url> [--via <ssh-session>]   (browser tab, optional SOCKS tunnel)
//   macmoba send --tab <index|title> <text>            (\n in text = Return)
//   macmoba read-screen --tab <index|title> [--lines N]
//   macmoba set-status --tab <index|title> <text>
//   macmoba notify --title <text> [--body <text>]
//
// Deliberately dependency-free: a blocking Unix-socket client is 60 lines and
// keeps this helper binary tiny.

import Darwin
import Foundation

// MARK: - locate the app's socket + token

// $HOME first (homeDirectoryForCurrentUser ignores the environment, which
// breaks test isolation and surprises anyone using HOME= overrides).
let homeDirectory = ProcessInfo.processInfo.environment["HOME"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser
let supportDir = homeDirectory
    .appendingPathComponent("Library/Application Support/MacMoba", isDirectory: true)
let socketPath = ProcessInfo.processInfo.environment["MACMOBA_SOCKET"]
    ?? supportDir.appendingPathComponent("control.sock").path
let tokenPath = ProcessInfo.processInfo.environment["MACMOBA_TOKEN_FILE"]
    ?? supportDir.appendingPathComponent("control.token").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - argument parsing (tiny: flags anywhere, first bare word = cmd)

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    fail("""
    usage: macmoba <command> [options]
      ping | list-tabs | open <session> | open-url <url> [--via <ssh-session>]
      send --tab <t> <text> | read-screen --tab <t> [--lines N]
      set-status --tab <t> <text> | notify --title <text> [--body <text>]
      agent-event --source <s> --event <e> [--body <text>] | hooks install claude
    """)
}

var flags: [String: String] = [:]
var positional: [String] = []
var index = 0
while index < args.count {
    let arg = args[index]
    if arg.hasPrefix("--") {
        let key = String(arg.dropFirst(2))
        guard index + 1 < args.count else { fail("missing value for --\(key)") }
        flags[key] = args[index + 1]
        index += 2
    } else {
        positional.append(arg)
        index += 1
    }
}
let cmd = positional.removeFirst()

// `hooks` edits local agent config; it neither needs nor wants a running app.
if cmd == "hooks" { Hooks.run(positional) }

var requestArgs = flags
switch cmd {
case "open" where !positional.isEmpty:
    requestArgs["session"] = positional.joined(separator: " ")
case "open-url" where !positional.isEmpty:
    requestArgs["url"] = positional[0]
case "send", "set-status":
    if !positional.isEmpty { requestArgs["text"] = positional.joined(separator: " ") }
default:
    break
}
// agent-event: the calling hook passes context implicitly — the event JSON
// arrives on stdin (Claude Code does this) and the owning tab in MACMOBA_TAB
// (exported into MacMoba's local terminals). Explicit flags still win.
if cmd == "agent-event" {
    if requestArgs["tab"] == nil,
       let tab = ProcessInfo.processInfo.environment["MACMOBA_TAB"] {
        requestArgs["tab"] = tab
    }
    if requestArgs["body"] == nil, isatty(0) == 0 {
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        if let object = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
            let message = (object["message"] as? String)
                ?? (object["title"] as? String)
                ?? (object["notification"] as? String)
            if let message, !message.isEmpty { requestArgs["body"] = message }
        }
    }
}

// Shell-friendly escapes in send text: \n → newline (Return), \t → tab.
if cmd == "send", let text = requestArgs["text"] {
    requestArgs["text"] = text
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\t", with: "\t")
}

guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
    fail("no control token at \(tokenPath) — is MacMoba running?")
}

// MARK: - one JSON line over the Unix socket

struct Request: Encodable { let token: String; let cmd: String; let args: [String: String] }
struct Response: Decodable { let ok: Bool; let data: String?; let error: String? }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("socket: \(String(cString: strerror(errno)))") }
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let ok = socketPath.withCString { pathBytes -> Bool in
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
    guard strlen(pathBytes) <= maxLen else { return false }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        _ = strcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), pathBytes)
    }
    return true
}
guard ok else { fail("socket path too long: \(socketPath)") }

let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    fail("cannot reach MacMoba at \(socketPath) — is the app running?")
}

let payload = try! JSONEncoder().encode(Request(token: token, cmd: cmd, args: requestArgs))
var line = payload
line.append(0x0A)
_ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

// Read until the newline that ends the response.
var responseData = Data()
var buf = [UInt8](repeating: 0, count: 4096)
while !responseData.contains(0x0A) {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    responseData.append(contentsOf: buf[0..<n])
}
guard let newline = responseData.firstIndex(of: 0x0A) else { fail("no response") }
let responseLine = responseData[..<newline]

guard let response = try? JSONDecoder().decode(Response.self, from: responseLine) else {
    fail("unparseable response: \(String(decoding: responseLine, as: UTF8.self))")
}
if response.ok {
    if let data = response.data { print(data) }
    exit(0)
} else {
    fail(response.error ?? "unknown error")
}

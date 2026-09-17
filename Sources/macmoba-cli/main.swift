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
//   macmoba mcp                                    (MCP server over stdio)
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
      mcp   (Model Context Protocol server over stdio — claude mcp add macmoba -- macmoba mcp)
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

// `mcp` serves tools over stdio until the client hangs up. It reaches the
// app per tool call, so starting it does not require the app to be running —
// tools fail politely instead, which is what an agent can act on.
if cmd == "mcp" { MCPServer.run(socketPath: socketPath, tokenPath: tokenPath) }

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

// MARK: - one JSON line over the Unix socket

do {
    let response = try ControlClient.call(cmd: cmd, args: requestArgs,
                                          socketPath: socketPath, tokenPath: tokenPath)
    if response.ok {
        if let data = response.data { print(data) }
        exit(0)
    } else {
        fail(response.error ?? "unknown error")
    }
} catch let error as ControlClientError {
    fail(error.message)
}

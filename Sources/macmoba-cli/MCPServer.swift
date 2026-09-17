// `macmoba mcp` — the control socket, spoken as MCP.
//
// A Model Context Protocol server over stdio: newline-delimited JSON-RPC 2.0
// in both directions, one JSON message per line. An MCP client (Claude Code,
// Claude Desktop) spawns this process and calls the app's control commands as
// tools instead of shelling out:
//
//   claude mcp add macmoba -- macmoba mcp
//
// This process is a translator and nothing more. Every tool call becomes one
// request over the same Unix socket the one-shot CLI uses, so the app remains
// the single place that authenticates (token), authorizes (the agent-typing
// setting) and executes. Keeping policy in the app matters: the socket is the
// boundary that every client crosses, so a rule enforced there cannot be
// skipped by talking to the socket directly.
//
// Two levels of failure, deliberately distinct:
//  - JSON-RPC errors (unknown method, malformed request) — protocol trouble,
//    for the client.
//  - Tool results with isError: true — the tool ran and failed ("no such
//    tab", "MacMoba is not running") — working information, for the model.
// Collapsing the second into the first would hide from the model exactly the
// errors it could react to.
//
// stdout carries JSON-RPC and NOTHING else; any diagnostic goes to stderr.
// A stray print here corrupts the protocol stream.

import Foundation

enum MCPServer {
    // MARK: - the tool table

    /// One control command, presented as a tool.
    private struct Tool {
        let name: String
        let description: String
        /// JSON Schema `properties` — every value here is a string schema
        /// unless marked integer.
        let params: [(name: String, type: String, doc: String, required: Bool)]
        /// The control-socket command this translates to.
        let cmd: String
        /// Extra args stamped onto every call (e.g. the agent marker).
        let fixedArgs: [String: String]
    }

    private static let tools: [Tool] = [
        Tool(name: "list_tabs",
             description: "List MacMoba's open tabs: index, title, kind "
                + "(ssh/local/rdp/vnc/web), connection state, and which "
                + "terminal engine draws it. Read-only.",
             params: [],
             cmd: "list-tabs", fixedArgs: [:]),
        Tool(name: "read_screen",
             description: "Read the text of a terminal tab, scrollback "
                + "included. Read-only. Use list_tabs first to find the tab.",
             params: [
                ("tab", "string", "Tab index or title, from list_tabs.", true),
                ("lines", "integer", "Only the last N lines.", false),
             ],
             cmd: "read-screen", fixedArgs: [:]),
        Tool(name: "open_session",
             description: "Open a saved MacMoba session by name, as a new tab.",
             params: [("session", "string", "The saved session's name.", true)],
             cmd: "open", fixedArgs: [:]),
        Tool(name: "open_url",
             description: "Open a URL in a MacMoba web tab, optionally "
                + "tunnelled through a saved SSH session's SOCKS proxy — the "
                + "way to reach a page only an internal network can see.",
             params: [
                ("url", "string", "The address to open.", true),
                ("via", "string", "Name of the SSH session to tunnel through.", false),
             ],
             cmd: "open-url", fixedArgs: [:]),
        Tool(name: "send_text",
             description: "Type text into a terminal tab. \\n sends Return. "
                + "Disabled unless the user has enabled \"Allow agents to "
                + "type into terminals\" in MacMoba's settings.",
             params: [
                ("tab", "string", "Tab index or title, from list_tabs.", true),
                ("text", "string", "Text to type. \\n for Return, \\t for Tab.", true),
             ],
             // The marker the app's gate looks for. The gate lives in the
             // app, not here: every path to the socket crosses it there.
             cmd: "send", fixedArgs: ["agent": "1"]),
        Tool(name: "notify",
             description: "Show a macOS notification from MacMoba.",
             params: [
                ("title", "string", "Notification title.", true),
                ("body", "string", "Notification body.", false),
             ],
             cmd: "notify", fixedArgs: [:]),
    ]

    // MARK: - the loop

    static func run(socketPath: String, tokenPath: String) -> Never {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let reply = handle(trimmed, socketPath: socketPath, tokenPath: tokenPath) {
                emit(reply)
            }
        }
        // EOF: the client hung up; a clean end, not an error.
        exit(0)
    }

    /// One message in, at most one message out. Nil for notifications —
    /// answering a notification is a protocol violation.
    static func handle(_ line: String, socketPath: String,
                       tokenPath: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // Parse errors have no usable id; the spec says answer null.
            return rpcError(id: NSNull(), code: -32700, message: "parse error")
        }

        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        // A message without an id is a notification; nothing may be sent back.
        guard let id else { return nil }

        switch method {
        case "initialize":
            // Echo the client's protocol version: this server's surface is
            // small enough to be a subset of every revision so far.
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            return rpcResult(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "macmoba", "version": "1.0"],
            ])

        case "ping":
            return rpcResult(id: id, [:])

        case "tools/list":
            return rpcResult(id: id, ["tools": tools.map(describe)])

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let tool = tools.first(where: { $0.name == name }) else {
                return rpcError(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            return rpcResult(id: id, callTool(tool, arguments: arguments,
                                              socketPath: socketPath,
                                              tokenPath: tokenPath))

        default:
            return rpcError(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    // MARK: - tool execution

    private static func callTool(_ tool: Tool, arguments: [String: Any],
                                 socketPath: String,
                                 tokenPath: String) -> [String: Any] {
        var args = tool.fixedArgs
        for param in tool.params {
            guard let value = arguments[param.name] else {
                if param.required {
                    return toolFailure("missing required argument: \(param.name)")
                }
                continue
            }
            // Everything on the control socket is a string; numbers arrive
            // here as NSNumber and leave as their decimal text.
            args[param.name] = (value as? String) ?? "\(value)"
        }
        do {
            let response = try ControlClient.call(cmd: tool.cmd, args: args,
                                                  socketPath: socketPath,
                                                  tokenPath: tokenPath)
            if response.ok {
                return ["content": [["type": "text",
                                     "text": response.data ?? "ok"]]]
            }
            return toolFailure(response.error ?? "unknown error")
        } catch let error as ControlClientError {
            return toolFailure(error.message)
        } catch {
            return toolFailure("\(error)")
        }
    }

    /// A tool that ran and failed — result with isError, never an RPC error,
    /// so the model sees what went wrong and can act on it.
    private static func toolFailure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: - serialization

    private static func describe(_ tool: Tool) -> [String: Any] {
        var properties: [String: Any] = [:]
        for param in tool.params {
            properties[param.name] = ["type": param.type,
                                      "description": param.doc]
        }
        return [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": tool.params.filter(\.required).map(\.name),
            ],
        ]
    }

    private static func rpcResult(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id,
         "error": ["code": code, "message": message]]
    }

    /// One line out, written unbuffered. `print` block-buffers on a pipe,
    /// and a buffered reply is a reply the client never sees.
    private static func emit(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message,
                                                     options: [.sortedKeys]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

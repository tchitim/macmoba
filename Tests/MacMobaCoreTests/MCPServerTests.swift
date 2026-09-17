import XCTest

/// `macmoba mcp`, tested the way an MCP client uses it: spawn the built CLI,
/// speak newline-delimited JSON-RPC over its stdin/stdout, and read what
/// comes back. Where a tool has to reach the app, a fake control server on a
/// scratch Unix socket stands in — which also lets these tests assert what
/// actually crossed the socket, such as the agent marker on send_text.
final class MCPServerTests: XCTestCase {

    private var cli: String!
    private var scratch: URL!

    override func setUpWithError() throws {
        cli = FileManager.default.currentDirectoryPath + "/.build/debug/macmoba-cli"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli),
                          "CLI not built at \(cli!)")
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-mcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - a running `macmoba mcp`

    private final class MCPProcess {
        let process = Process()
        private let stdin = Pipe()
        private let stdout = Pipe()
        private var buffer = Data()

        init(cli: String, socket: String, tokenFile: String) throws {
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["mcp"]
            var env = ProcessInfo.processInfo.environment
            env["MACMOBA_SOCKET"] = socket
            env["MACMOBA_TOKEN_FILE"] = tokenFile
            process.environment = env
            process.standardInput = stdin
            process.standardOutput = stdout
            try process.run()
        }

        func send(_ message: [String: Any]) {
            var data = try! JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            stdin.fileHandleForWriting.write(data)
        }

        /// The next reply line, or nil if none arrives in time. Polling with
        /// availableData keeps this free of readabilityHandler races.
        func nextReply(timeout: TimeInterval = 5) -> [String: Any]? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                }
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.02) }
                buffer.append(chunk)
            }
            return nil
        }

        func stop() {
            stdin.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        }
    }

    private func startServer(socket: String? = nil,
                             tokenFile: String? = nil) throws -> MCPProcess {
        try MCPProcess(cli: cli,
                       socket: socket ?? scratch.appendingPathComponent("none.sock").path,
                       tokenFile: tokenFile
                           ?? scratch.appendingPathComponent("no-token").path)
    }

    // MARK: - protocol

    func testInitializeEchoesTheClientsProtocolVersion() throws {
        let mcp = try startServer()
        defer { mcp.stop() }
        mcp.send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": ["protocolVersion": "2024-11-05"]])
        let reply = try XCTUnwrap(mcp.nextReply())
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "macmoba")
    }

    func testToolsListNamesTheTools() throws {
        let mcp = try startServer()
        defer { mcp.stop() }
        mcp.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let reply = try XCTUnwrap(mcp.nextReply())
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["list_tabs", "read_screen", "open_session",
                               "open_url", "send_text", "notify"])
        // Every tool must carry a schema an MCP client can validate against.
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any],
                                       "\(tool["name"] ?? "?") has no schema")
            XCTAssertEqual(schema["type"] as? String, "object")
        }
    }

    func testUnknownMethodIsAnRPCError() throws {
        let mcp = try startServer()
        defer { mcp.stop() }
        mcp.send(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        let reply = try XCTUnwrap(mcp.nextReply())
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    /// Notifications get no reply — answering one is a protocol violation,
    /// and the next real request's reply must not be displaced by one.
    func testNotificationIsSilent() throws {
        let mcp = try startServer()
        defer { mcp.stop() }
        mcp.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        mcp.send(["jsonrpc": "2.0", "id": 4, "method": "ping"])
        let reply = try XCTUnwrap(mcp.nextReply())
        XCTAssertEqual(reply["id"] as? Int, 4, "the first reply must answer ping")
    }

    // MARK: - tools

    /// Tool-level trouble is a result with isError, not an RPC error: the
    /// model can read "is MacMoba running?" and tell the user; a bare -32603
    /// tells it nothing.
    func testToolCallWithoutTheAppFailsAsAToolResult() throws {
        let mcp = try startServer()
        defer { mcp.stop() }
        mcp.send(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                  "params": ["name": "list_tabs", "arguments": [String: Any]()]])
        let reply = try XCTUnwrap(mcp.nextReply())
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("is MacMoba running"), text)
    }

    func testMissingRequiredArgumentIsAToolResult() throws {
        let mcp = try startServer()
        defer { mcp.stop() }
        mcp.send(["jsonrpc": "2.0", "id": 6, "method": "tools/call",
                  "params": ["name": "read_screen", "arguments": [String: Any]()]])
        let reply = try XCTUnwrap(mcp.nextReply())
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String,
                       "missing required argument: tab")
    }

    // MARK: - through a fake app

    /// A stand-in control server: accepts one connection, records the request
    /// line, answers with a fixed response. Just enough socket to prove what
    /// the MCP layer put on the wire.
    private final class FakeApp {
        let path: String
        private(set) var received: [String: Any]?
        private let fd: Int32
        private let done = DispatchSemaphore(value: 0)

        init?(path: String, reply: String) {
            self.path = path
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let ok = path.withCString { bytes -> Bool in
                guard strlen(bytes) <= MemoryLayout.size(ofValue: addr.sun_path) - 1
                else { return false }
                withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                    _ = strcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), bytes)
                }
                return true
            }
            guard ok else { return nil }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return nil }
            Thread.detachNewThread { [self] in
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { done.signal(); return }
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while !data.contains(0x0A) {
                    let n = read(client, &buf, buf.count)
                    if n <= 0 { break }
                    data.append(contentsOf: buf[0..<n])
                }
                if let newline = data.firstIndex(of: 0x0A) {
                    received = (try? JSONSerialization.jsonObject(with: data[..<newline]))
                        as? [String: Any]
                }
                _ = (reply + "\n").withCString { write(client, $0, strlen($0)) }
                close(client)
                done.signal()
            }
        }

        func wait() { _ = done.wait(timeout: .now() + 5) }
        deinit { close(fd); unlink(path) }
    }

    func testSendTextCarriesTheAgentMarkerAndTheToken() throws {
        let socketPath = scratch.appendingPathComponent("app.sock").path
        let tokenFile = scratch.appendingPathComponent("token")
        try "sekrit".write(to: tokenFile, atomically: true, encoding: .utf8)
        let app = try XCTUnwrap(FakeApp(path: socketPath,
                                        reply: #"{"ok":true,"data":"sent"}"#))

        let mcp = try startServer(socket: socketPath, tokenFile: tokenFile.path)
        defer { mcp.stop() }
        mcp.send(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                  "params": ["name": "send_text",
                             "arguments": ["tab": "1", "text": "ls\n"]]])
        let reply = try XCTUnwrap(mcp.nextReply())
        app.wait()

        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "the fake app said ok")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "sent")

        // What crossed the socket is the contract: the app's opt-in gate
        // keys on the marker, and the token is how the app knows its caller.
        let request = try XCTUnwrap(app.received)
        XCTAssertEqual(request["cmd"] as? String, "send")
        XCTAssertEqual(request["token"] as? String, "sekrit")
        let args = try XCTUnwrap(request["args"] as? [String: String])
        XCTAssertEqual(args["agent"], "1")
        XCTAssertEqual(args["tab"], "1")
        XCTAssertEqual(args["text"], "ls\n")
    }

    func testReadScreenPassesLinesAsDecimalText() throws {
        let socketPath = scratch.appendingPathComponent("app2.sock").path
        let tokenFile = scratch.appendingPathComponent("token2")
        try "t".write(to: tokenFile, atomically: true, encoding: .utf8)
        let app = try XCTUnwrap(FakeApp(path: socketPath,
                                        reply: #"{"ok":true,"data":"{\"text\":\"$ \"}"}"#))

        let mcp = try startServer(socket: socketPath, tokenFile: tokenFile.path)
        defer { mcp.stop() }
        mcp.send(["jsonrpc": "2.0", "id": 8, "method": "tools/call",
                  "params": ["name": "read_screen",
                             "arguments": ["tab": "MacMini", "lines": 40]]])
        _ = try XCTUnwrap(mcp.nextReply())
        app.wait()

        let args = try XCTUnwrap(app.received?["args"] as? [String: String])
        // The JSON number 40 must arrive as "40" — the control protocol is
        // strings end to end, and "40.0" would fail the app's Int parse.
        XCTAssertEqual(args["lines"], "40")
        XCTAssertEqual(args["tab"], "MacMini")
    }
}

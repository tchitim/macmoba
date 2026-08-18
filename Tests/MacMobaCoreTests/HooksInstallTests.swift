import XCTest

/// `macmoba hooks install claude`, verified against the real file it writes:
/// the tests spawn the built CLI with HOME pointed at a scratch directory and
/// read ~/.claude/settings.json back. No app, no socket — pure file contract.
final class HooksInstallTests: XCTestCase {

    private var home: URL!
    private var cli: String!

    override func setUpWithError() throws {
        cli = FileManager.default.currentDirectoryPath + "/.build/debug/macmoba-cli"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli),
                          "CLI not built at \(cli!)")
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-hooks-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func runCLI(_ args: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
        return (process.terminationStatus, output)
    }

    private func settings() throws -> [String: Any] {
        let url = home.appendingPathComponent(".claude/settings.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(in root: [String: Any], event: String) -> [String] {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let entries = hooks[event] as? [[String: Any]] ?? []
        return entries.flatMap { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? [])
                .compactMap { $0["command"] as? String }
        }
    }

    func testInstallWritesNotificationAndStopHooks() throws {
        let result = try runCLI(["hooks", "install", "claude"])
        XCTAssertEqual(result.status, 0, result.output)
        let root = try settings()
        for event in ["Notification", "Stop"] {
            let cmds = commands(in: root, event: event)
            XCTAssertEqual(cmds.count, 1, "\(event): \(cmds)")
            XCTAssertTrue(cmds[0].contains("agent-event"), cmds[0])
            XCTAssertTrue(cmds[0].contains("--event \(event)"), cmds[0])
            XCTAssertTrue(cmds[0].hasPrefix("/"), "command must be an absolute path: \(cmds[0])")
        }
    }

    func testInstallIsIdempotent() throws {
        _ = try runCLI(["hooks", "install", "claude"])
        _ = try runCLI(["hooks", "install", "claude"])
        let root = try settings()
        XCTAssertEqual(commands(in: root, event: "Notification").count, 1,
                       "second install must not duplicate")
    }

    func testInstallPreservesExistingSettingsAndBacksUp() throws {
        // A user's real file: a foreign setting plus their own Stop hook.
        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = """
        {"model":"opus","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"say done"}]}]}}
        """
        try existing.write(to: dir.appendingPathComponent("settings.json"),
                           atomically: true, encoding: .utf8)

        _ = try runCLI(["hooks", "install", "claude"])
        let root = try settings()
        XCTAssertEqual(root["model"] as? String, "opus", "foreign keys must survive")
        let stops = commands(in: root, event: "Stop")
        XCTAssertTrue(stops.contains("say done"), "user's own hook must survive: \(stops)")
        XCTAssertTrue(stops.contains { $0.contains("agent-event") })
        // And a backup of the original exists.
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("settings.json.bak-") }
        XCTAssertFalse(backups.isEmpty, "no backup written")
    }

    func testUninstallRemovesOnlyOurs() throws {
        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"say done"}]}]}}"#
            .write(to: dir.appendingPathComponent("settings.json"),
                   atomically: true, encoding: .utf8)
        _ = try runCLI(["hooks", "install", "claude"])
        _ = try runCLI(["hooks", "uninstall", "claude"])
        let root = try settings()
        let stops = commands(in: root, event: "Stop")
        XCTAssertEqual(stops, ["say done"], "only MacMoba's entries go: \(stops)")
        XCTAssertTrue(commands(in: root, event: "Notification").isEmpty)
    }

    func testCodexPrintsSnippetWithoutTouchingFiles() throws {
        let result = try runCLI(["hooks", "install", "codex"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("notify = ["), result.output)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".codex/config.toml").path),
            "codex config must not be edited")
    }
}

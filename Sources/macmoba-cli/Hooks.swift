// `macmoba hooks …` — wire an AI agent's own hook system to MacMoba, so
// "finished" / "needs approval" reaches the tab badge and notification centre
// with real semantics instead of a bell guess.
//
// Claude Code: hooks live in ~/.claude/settings.json. `install` merges our
// Notification and Stop entries (absolute CLI path, so no PATH games), backing
// the file up first; `uninstall` removes exactly what we added. Codex keeps
// its config in TOML, which is not worth editing blindly — we print the two
// lines to paste instead.

import Foundation

enum Hooks {
    static func run(_ positional: [String]) -> Never {
        guard positional.count >= 2 else {
            fail("""
            usage: macmoba hooks <install|uninstall> claude
                   macmoba hooks install codex     (prints config to paste)
            """)
        }
        let action = positional[0]
        let agent = positional[1]
        switch (action, agent) {
        case ("install", "claude"): installClaude()
        case ("uninstall", "claude"): uninstallClaude()
        case ("install", "codex"): printCodexSnippet()
        default:
            fail("unsupported: hooks \(action) \(agent) (claude install/uninstall, codex install)")
        }
    }

    // MARK: - Claude Code (~/.claude/settings.json)

    private static var settingsURL: URL {
        // $HOME first: homeDirectoryForCurrentUser reads the passwd entry and
        // IGNORES the environment, which breaks test isolation — and once bit
        // this project by writing into the real ~/.claude during a test.
        let home = ProcessInfo.processInfo.environment["HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json")
    }

    /// The command Claude Code will run. `agent-event` reads the hook's JSON
    /// from stdin for the message text; MACMOBA_TAB (exported into MacMoba's
    /// local terminals) tells it which tab the agent lives in.
    private static func hookCommand(event: String) -> String {
        let cli = CommandLine.arguments[0].hasPrefix("/")
            ? CommandLine.arguments[0]
            : FileManager.default.currentDirectoryPath + "/" + CommandLine.arguments[0]
        return "\(cli) agent-event --source claude --event \(event)"
    }

    private static func installClaude() -> Never {
        let url = settingsURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fail("\(url.path) exists but is not a JSON object — not touching it")
            }
            root = existing
            // Timestamped backup before the first byte changes.
            let backup = url.path + ".bak-\(Int(Date().timeIntervalSince1970))"
            try? data.write(to: URL(fileURLWithPath: backup))
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in ["Notification", "Stop"] {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let command = hookCommand(event: event)
            let already = entries.contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains("macmoba") == true
                        && ($0["command"] as? String)?.contains("agent-event") == true
                }
            }
            if !already {
                entries.append(["matcher": "",
                                "hooks": [["type": "command", "command": command]]])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url)
        } catch {
            fail("could not write \(url.path): \(error.localizedDescription)")
        }
        print("Claude Code hooks installed (Notification + Stop) in \(url.path)")
        print("Restart Claude Code sessions to pick them up.")
        exit(0)
    }

    private static func uninstallClaude() -> Never {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            print("nothing to uninstall")
            exit(0)
        }
        for event in ["Notification", "Stop"] {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains("macmoba") == true
                        && ($0["command"] as? String)?.contains("agent-event") == true
                }
            }
            if entries.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = entries }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        if let out = try? JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url)
        }
        print("MacMoba hooks removed from \(url.path)")
        exit(0)
    }

    // MARK: - Codex (config.toml — printed, not edited)

    private static func printCodexSnippet() -> Never {
        let command = hookCommand(event: "notify")
        print("""
        Add to ~/.codex/config.toml (TOML is easy to corrupt, so paste this yourself):

        notify = [\(command.split(separator: " ").map { "\"\($0)\"" }.joined(separator: ", "))]
        """)
        exit(0)
    }
}

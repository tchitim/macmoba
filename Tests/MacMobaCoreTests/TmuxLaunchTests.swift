import XCTest
@testable import MacMobaCore

final class TmuxLaunchTests: XCTestCase {

    // MARK: - the session name

    func testNameIsStableForTheSameSessionAndPane() {
        // The whole point: a reconnect must compute the SAME name, or it opens
        // a second empty session instead of reattaching.
        let a = TmuxLaunch.sessionName(sessionID: "abc-123", paneIndex: 0)
        let b = TmuxLaunch.sessionName(sessionID: "abc-123", paneIndex: 0)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "mm-abc-123-0")
    }

    func testPanesOfOneSessionGetDistinctNames() {
        XCTAssertNotEqual(
            TmuxLaunch.sessionName(sessionID: "s", paneIndex: 0),
            TmuxLaunch.sessionName(sessionID: "s", paneIndex: 1))
    }

    /// tmux reads `.` and `:` as window/pane addresses, and matches a name as
    /// a prefix. A UUID's characters are safe, but a session id could be
    /// anything, so everything outside the safe set folds to `_`.
    func testUnsafeCharactersAreFolded() {
        let name = TmuxLaunch.sessionName(sessionID: "a.b:c d/e", paneIndex: 2)
        XCTAssertEqual(name, "mm-a_b_c_d_e-2")
        XCTAssertFalse(name.contains("."))
        XCTAssertFalse(name.contains(":"))
    }

    func testALongIdIsCapped() {
        let name = TmuxLaunch.sessionName(sessionID: String(repeating: "x", count: 200),
                                          paneIndex: 0)
        // mm- (3) + 48 + -0 (2)
        XCTAssertEqual(name.count, 53)
    }

    // MARK: - the launch command

    func testDisabledIsNil() {
        XCTAssertNil(TmuxLaunch.launchCommand(enabled: false,
                                              sessionID: "s", paneIndex: 0))
    }

    func testEnabledProbesAndFallsBack() {
        let cmd = TmuxLaunch.launchCommand(enabled: true,
                                           sessionID: "s", paneIndex: 0)
        let command = try! XCTUnwrap(cmd)
        // Probe with command -v (a POSIX builtin, unlike `which`), attach or
        // create with -A, and fall back to a login shell so a remote without
        // tmux still opens.
        XCTAssertTrue(command.contains("command -v tmux"), command)
        XCTAssertTrue(command.contains("new-session -A -s \"mm-s-0\""), command)
        XCTAssertTrue(command.contains("|| exec"), command)
        XCTAssertTrue(command.contains("SHELL"), command)
        // Three execs: the outer login shell, then tmux OR the fallback shell —
        // whichever branch runs replaces the process, so nothing lingers.
        XCTAssertEqual(command.components(separatedBy: "exec ").count - 1, 3)
    }

    /// The probe runs under a login shell (`-lc`), not the bare non-login shell
    /// sshd's exec channel provides. Without this, a Homebrew/`/usr/local` tmux
    /// is off PATH, the probe reports it missing, and the session silently
    /// falls back to a plain shell — tmux looks broken though it is installed.
    func testProbeRunsUnderALoginShell() {
        let cmd = try! XCTUnwrap(TmuxLaunch.launchCommand(enabled: true,
                                                          sessionID: "s", paneIndex: 0))
        // The command's first act is to re-exec a login shell, and the tmux
        // probe lives inside that login shell's `-lc` body.
        XCTAssertTrue(cmd.hasPrefix("exec \"${SHELL:-/bin/sh}\" -lc '"), cmd)
        let probeIndex = try! XCTUnwrap(cmd.range(of: "command -v tmux"))
        let lcIndex = try! XCTUnwrap(cmd.range(of: "-lc '"))
        XCTAssertLessThan(lcIndex.lowerBound, probeIndex.lowerBound,
                          "the login shell must be entered before the probe: \(cmd)")
    }

    /// The name inside the command matches the name the reattach will look
    /// for — they come from the same function, and this proves the wiring did
    /// not drift.
    func testCommandUsesTheStableName() {
        let name = TmuxLaunch.sessionName(sessionID: "host-9", paneIndex: 1)
        let cmd = try! XCTUnwrap(TmuxLaunch.launchCommand(enabled: true,
                                                          sessionID: "host-9",
                                                          paneIndex: 1))
        XCTAssertTrue(cmd.contains("\"\(name)\""), cmd)
    }

    // MARK: - it stays off the wire when unused

    func testConfigDefaultsToNoTmux() {
        let config = SessionConfig(name: "s", host: "h", port: 22, username: "u")
        XCTAssertNil(config.useTmux)
        XCTAssertNil(TmuxLaunch.launchCommand(enabled: config.useTmux == true,
                                              sessionID: config.id, paneIndex: 0))
    }

    /// The exact wiring `TerminalTab.connectSSH` uses: a config with tmux on and
    /// a chosen name must produce an attach command for THAT name. This locks
    /// the SSH path end to end — a config field that stops reaching the launch
    /// command would fail here rather than only on a live connection.
    func testConfigWithTmuxAndNameBuildsAttachCommand() {
        var config = SessionConfig(name: "s", host: "h", port: 22, username: "u")
        config.useTmux = true
        config.tmuxSession = "work"
        let cmd = try! XCTUnwrap(TmuxLaunch.launchCommand(
            enabled: config.useTmux == true,
            sessionID: config.id, paneIndex: 0,
            explicitName: config.tmuxSession))
        XCTAssertTrue(cmd.contains("new-session -A -s \"work\""), cmd)
    }

    /// tmux on but no chosen name falls to the stable generated name, so a
    /// reconnect still finds the same session.
    func testConfigWithTmuxAndNoNameUsesGeneratedName() {
        var config = SessionConfig(name: "s", host: "h", port: 22, username: "u")
        config.useTmux = true
        config.tmuxSession = nil
        let cmd = try! XCTUnwrap(TmuxLaunch.launchCommand(
            enabled: config.useTmux == true,
            sessionID: config.id, paneIndex: 0,
            explicitName: config.tmuxSession))
        let expected = TmuxLaunch.sessionName(sessionID: config.id, paneIndex: 0)
        XCTAssertTrue(cmd.contains("new-session -A -s \"\(expected)\""), cmd)
    }
}

// MARK: - an explicit session name

extension TmuxLaunchTests {
    /// A name the user typed is used verbatim (folded), NOT prefixed with
    /// `mm-`: it is meant to match a session they made by hand on the server.
    func testExplicitNameIsUsedAsIs() {
        let name = TmuxLaunch.resolvedName(explicit: "work",
                                           sessionID: "s", paneIndex: 0)
        XCTAssertEqual(name, "work")
    }

    func testExplicitNameAppearsInTheCommand() {
        let cmd = try! XCTUnwrap(TmuxLaunch.launchCommand(
            enabled: true, sessionID: "s", paneIndex: 0, explicitName: "build"))
        XCTAssertTrue(cmd.contains("new-session -A -s \"build\""), cmd)
    }

    /// Unsafe characters in a typed name are folded the same as anywhere else,
    /// so the name that reaches tmux is always attachable.
    func testExplicitNameIsFolded() {
        XCTAssertEqual(
            TmuxLaunch.resolvedName(explicit: "my.work:1", sessionID: "s", paneIndex: 0),
            "my_work_1")
    }

    /// Blank or all-punctuation input is not a name; fall back to the stable
    /// generated one rather than attaching to a session called "" or "_".
    func testBlankExplicitNameFallsBackToGenerated() {
        for junk in ["", "   ", "..."] {
            XCTAssertEqual(
                TmuxLaunch.resolvedName(explicit: junk, sessionID: "s", paneIndex: 3),
                "mm-s-3")
        }
    }

    func testNilExplicitNameFallsBackToGenerated() {
        XCTAssertEqual(
            TmuxLaunch.resolvedName(explicit: nil, sessionID: "s", paneIndex: 0),
            "mm-s-0")
    }
}

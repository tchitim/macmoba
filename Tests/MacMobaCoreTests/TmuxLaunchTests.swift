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
        XCTAssertTrue(command.contains("new-session -A -s 'mm-s-0'"), command)
        XCTAssertTrue(command.contains("|| exec"), command)
        XCTAssertTrue(command.contains("SHELL"), command)
        // Both branches exec, so no probing shell is left as a parent process.
        XCTAssertEqual(command.components(separatedBy: "exec ").count - 1, 2)
    }

    /// The name inside the command matches the name the reattach will look
    /// for — they come from the same function, and this proves the wiring did
    /// not drift.
    func testCommandUsesTheStableName() {
        let name = TmuxLaunch.sessionName(sessionID: "host-9", paneIndex: 1)
        let cmd = try! XCTUnwrap(TmuxLaunch.launchCommand(enabled: true,
                                                          sessionID: "host-9",
                                                          paneIndex: 1))
        XCTAssertTrue(cmd.contains("'\(name)'"), cmd)
    }

    // MARK: - it stays off the wire when unused

    func testConfigDefaultsToNoTmux() {
        let config = SessionConfig(name: "s", host: "h", port: 22, username: "u")
        XCTAssertNil(config.useTmux)
        XCTAssertNil(TmuxLaunch.launchCommand(enabled: config.useTmux == true,
                                              sessionID: config.id, paneIndex: 0))
    }
}

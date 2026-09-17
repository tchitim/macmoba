import XCTest
@testable import MacMobaCore

final class FollowCommandTests: XCTestCase {

    func testPlainPath() {
        XCTAssertEqual(FollowCommand.command(path: "/var/log/syslog"),
                       "tail -n 100 -f -- '/var/log/syslog'")
    }

    func testLineCountIsHonoured() {
        XCTAssertEqual(FollowCommand.command(path: "/a", lines: 20),
                       "tail -n 20 -f -- '/a'")
    }

    /// A space in a path must not split into two arguments.
    func testPathWithSpaces() {
        XCTAssertEqual(FollowCommand.command(path: "/var/log/my app.log"),
                       "tail -n 100 -f -- '/var/log/my app.log'")
    }

    /// The one character single quotes cannot hold, spliced the standard way.
    /// Without this a path like a file called `it's.log` breaks out of the
    /// quotes and the rest of the path becomes shell code.
    func testPathWithASingleQuote() {
        XCTAssertEqual(FollowCommand.command(path: "/logs/it's.log"),
                       #"tail -n 100 -f -- '/logs/it'\''s.log'"#)
    }

    /// Metacharacters stay literal inside single quotes — a real concern,
    /// since a listing can name a file anything.
    func testPathWithMetacharacters() {
        let cmd = FollowCommand.command(path: "/tmp/$(rm -rf ~).log")
        XCTAssertEqual(cmd, "tail -n 100 -f -- '/tmp/$(rm -rf ~).log'")
        // The dangerous substring survives only as literal text between quotes.
        XCTAssertTrue(cmd.contains("'/tmp/$(rm -rf ~).log'"))
    }

    /// `--` guards a path that begins with a dash from being read as options.
    func testLeadingDashPath() {
        let cmd = FollowCommand.command(path: "-rf")
        XCTAssertTrue(cmd.contains("-f -- '-rf'"), cmd)
    }
}

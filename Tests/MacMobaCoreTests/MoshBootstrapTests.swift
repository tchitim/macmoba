import XCTest
@testable import MacMobaCore

/// Parsing mosh-server's greeting. This runs against whatever a real login
/// shell emitted, so the interesting cases are all about noise around the line
/// we want — and about failing with something a person can act on.
final class MoshBootstrapTests: XCTestCase {

    func testParsesTheConnectLine() throws {
        let session = try MoshBootstrap.parse("MOSH CONNECT 60001 rEzBna3rEz9zLTMHtLYQEg\n")
        XCTAssertEqual(session.port, 60001)
        XCTAssertEqual(session.key, "rEzBna3rEz9zLTMHtLYQEg")
    }

    /// A login shell prints motd, banners and warnings before our command runs.
    /// Assuming the first line would break on essentially every real server.
    func testFindsTheLineAmongLoginNoise() throws {
        let output = """
        Welcome to Ubuntu 22.04.3 LTS (GNU/Linux 5.15.0 x86_64)

         * Documentation:  https://help.ubuntu.com
        Last login: Tue Aug 10 09:14:22 2026 from 10.0.0.4

        MOSH CONNECT 60123 AbCdEfGhIjKlMnOpQrStUv

        """
        let session = try MoshBootstrap.parse(output)
        XCTAssertEqual(session.port, 60123)
        XCTAssertEqual(session.key, "AbCdEfGhIjKlMnOpQrStUv")
    }

    func testToleratesCarriageReturnsAndSurroundingSpace() throws {
        let session = try MoshBootstrap.parse("banner\r\n  MOSH CONNECT 61000 KEYKEYKEY  \r\n")
        XCTAssertEqual(session.port, 61000)
        XCTAssertEqual(session.key, "KEYKEYKEY")
    }

    /// By far the most common failure, and the one where a vague error wastes
    /// the most time: mosh simply is not installed on the far end.
    func testMissingServerIsReportedAsSuch() {
        let outputs = [
            "bash: mosh-server: command not found\n",
            "zsh: command not found: mosh-server\n",
            "sh: 1: mosh-server: not found\n",
        ]
        for output in outputs {
            XCTAssertThrowsError(try MoshBootstrap.parse(output)) { error in
                XCTAssertEqual(error as? MoshError, .serverNotFound,
                               "not recognised as a missing server: \(output)")
                let message = (error as? MoshError)?.errorDescription ?? ""
                XCTAssertTrue(message.contains("not installed"),
                              "unhelpful message: \(message)")
            }
        }
    }

    /// Anything else that went wrong should surface what the server actually
    /// said, because that is the only clue available.
    func testOtherFailuresQuoteTheServer() {
        let output = "mosh-server needs a UTF-8 native locale to run.\n"
        XCTAssertThrowsError(try MoshBootstrap.parse(output)) { error in
            guard case .noConnectLine(let captured)? = error as? MoshError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(captured.contains("UTF-8 native locale"))
            let message = (error as? MoshError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("UTF-8 native locale"),
                          "the server's own explanation must reach the user")
        }
    }

    func testEmptyOutputSaysSoRatherThanQuotingNothing() {
        XCTAssertThrowsError(try MoshBootstrap.parse("   \n\n")) { error in
            let message = (error as? MoshError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("no output"), "unhelpful message: \(message)")
        }
    }

    func testRejectsAConnectLineItCannotUse() {
        for line in ["MOSH CONNECT\n",
                     "MOSH CONNECT 60001\n",
                     "MOSH CONNECT notaport KEY\n",
                     "MOSH CONNECT 99999 KEY\n",
                     "MOSH CONNECT 0 KEY\n"] {
            XCTAssertThrowsError(try MoshBootstrap.parse(line), "accepted: \(line)") { error in
                XCTAssertEqual(error as? MoshError, .malformedConnectLine(
                    line.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    /// mosh-server refuses to start outside a UTF-8 locale, so the command has
    /// to set one rather than inherit whatever the SSH session had.
    func testServerCommandForcesAUTF8Locale() {
        let command = MoshBootstrap.serverCommand()
        XCTAssertTrue(command.contains("LANG=en_US.UTF-8"))
        XCTAssertTrue(command.contains("LC_ALL=en_US.UTF-8"))
        XCTAssertTrue(command.contains("mosh-server new"))
        // -s: bind to the address SSH arrived on, which is what makes this work
        // through NAT and jump hosts without us naming an address.
        XCTAssertTrue(command.contains(" -s"))
    }
}

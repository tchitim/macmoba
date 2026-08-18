import XCTest

@testable import MacMobaCore

/// The rename box is the one place a user's typing becomes part of a path on
/// another machine, so what it refuses matters more than what it accepts.
final class FileNameCheckTests: XCTestCase {
    func testOrdinaryNamesAreFine() {
        XCTAssertNil(FileNameCheck.rejection(for: "report.txt"))
        XCTAssertNil(FileNameCheck.rejection(for: "My Report (final).txt"))
        XCTAssertNil(FileNameCheck.rejection(for: ".bashrc"))
        XCTAssertNil(FileNameCheck.rejection(for: "資料夾"))
    }

    func testEmptyOrWhitespaceIsRefused() {
        XCTAssertNotNil(FileNameCheck.rejection(for: ""))
        XCTAssertNotNil(FileNameCheck.rejection(for: "   "))
    }

    /// A slash makes it a path, not a name: accepting it would move the file
    /// somewhere the user never asked for.
    func testASlashIsRefused() {
        let rejection = FileNameCheck.rejection(for: "sub/file.txt")
        XCTAssertNotNil(rejection)
        XCTAssertTrue(rejection!.contains("/"), rejection!)
    }

    /// "../../etc/passwd" is the reason this check exists.
    func testDotAndDotDotAreRefused() {
        XCTAssertNotNil(FileNameCheck.rejection(for: "."))
        XCTAssertNotNil(FileNameCheck.rejection(for: ".."))
        XCTAssertNotNil(FileNameCheck.rejection(for: "../secrets"),
                        "a traversal contains a slash and must be refused")
    }

    /// A NUL ends a C string, so anything after it would vanish on the way to
    /// the server — the name sent would not be the name typed.
    func testControlCharactersAreRefused() {
        XCTAssertNotNil(FileNameCheck.rejection(for: "file\u{0}.txt"))
        XCTAssertNotNil(FileNameCheck.rejection(for: "file\u{7}.txt"))
        XCTAssertNotNil(FileNameCheck.rejection(for: "line\nbreak.txt"))
    }

    func testTooLongIsRefused() {
        XCTAssertNil(FileNameCheck.rejection(for: String(repeating: "a", count: 255)))
        XCTAssertNotNil(FileNameCheck.rejection(for: String(repeating: "a", count: 256)))
    }

    /// Clashing with something already there would replace it, silently on
    /// some servers.
    func testAnExistingNameIsRefused() {
        let rejection = FileNameCheck.rejection(for: "taken.txt",
                                                existing: ["taken.txt", "other.txt"])
        XCTAssertNotNil(rejection)
        XCTAssertTrue(rejection!.contains("already exists"), rejection!)
    }

    /// Opening the box and pressing Rename without changing anything is not an
    /// error, even though the name obviously "already exists".
    func testRenamingToTheSameNameIsAllowed() {
        XCTAssertNil(FileNameCheck.rejection(for: "same.txt",
                                             existing: ["same.txt"],
                                             currentName: "same.txt"))
    }

    /// Surrounding spaces are almost always a paste accident, and a trailing
    /// space in a file name is invisible and maddening.
    func testSurroundingSpaceIsTrimmedNotRejected() {
        XCTAssertNil(FileNameCheck.rejection(for: "  spaced.txt  "))
        XCTAssertEqual(FileNameCheck.cleaned("  spaced.txt  "), "spaced.txt")
    }

    func testTrimmingIsAppliedBeforeTheClashCheck() {
        XCTAssertNotNil(FileNameCheck.rejection(for: " taken.txt ", existing: ["taken.txt"]))
    }
}

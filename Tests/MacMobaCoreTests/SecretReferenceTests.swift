import XCTest

@testable import MacMobaCore

final class SecretReferenceTests: XCTestCase {
    func testPlainPasswordIsLiteral() {
        XCTAssertEqual(SecretReference.parse("hunter2"), .literal("hunter2"))
        XCTAssertFalse(SecretReference.parse("hunter2").isReference)
        XCTAssertNil(SecretReference.parse("hunter2").fetchArgv())
    }

    func testOnePasswordReference() {
        let ref = SecretReference.parse("op://Private/prod-db/password")
        XCTAssertEqual(ref, .onePassword("op://Private/prod-db/password"))
        XCTAssertTrue(ref.isReference)
        XCTAssertEqual(ref.fetchArgv(),
                       ["/usr/bin/env", "op", "read", "--no-newline",
                        "op://Private/prod-db/password"])
    }

    func testCommandReference() {
        let ref = SecretReference.parse("cmd:security find-generic-password -s ssh -w")
        XCTAssertEqual(ref, .command("security find-generic-password -s ssh -w"))
        XCTAssertTrue(ref.isReference)
        XCTAssertEqual(ref.fetchArgv(),
                       ["/bin/sh", "-c", "security find-generic-password -s ssh -w"])
    }

    /// A literal that merely contains a colon is not a command.
    func testColonInLiteralIsNotACommand() {
        XCTAssertEqual(SecretReference.parse("a:b:c"), .literal("a:b:c"))
    }

    /// Spaces matter for a real password — they must not be trimmed away.
    func testLiteralKeepsSurroundingSpaces() {
        XCTAssertEqual(SecretReference.parse("  spaced  "), .literal("  spaced  "))
    }

    func testEmptyCommandIsStillACommand() {
        XCTAssertEqual(SecretReference.parse("cmd:"), .command(""))
    }

    // MARK: - quoted references (pasted from shell examples)

    /// The exact field a user produced by copying `op read "op://…"` out of a
    /// terminal example — quotes included. Must still be a reference, unquoted.
    func testDoubleQuotedOnePasswordReference() {
        XCTAssertEqual(SecretReference.parse("\"op://Personal/example-server/password\""),
                       .onePassword("op://Personal/example-server/password"))
    }

    func testSingleQuotedAndPaddedReference() {
        XCTAssertEqual(SecretReference.parse("  'op://v/i/password'  "),
                       .onePassword("op://v/i/password"))
    }

    /// macOS smart substitution curls typed quotes; the reference survives.
    func testCurlyQuotedReference() {
        XCTAssertEqual(SecretReference.parse("\u{201C}op://v/i/password\u{201D}"),
                       .onePassword("op://v/i/password"))
    }

    func testQuotedCommandReference() {
        XCTAssertEqual(SecretReference.parse("\"cmd:printf x\""), .command("printf x"))
    }

    /// A quoted string that is NOT a reference stays a literal — raw, quotes
    /// and all: quotes are legal characters in real passwords.
    func testQuotedLiteralIsUntouched() {
        XCTAssertEqual(SecretReference.parse("\"hunter2\""), .literal("\"hunter2\""))
    }

    /// A reference with only a leading quote (typo) does not half-match.
    func testUnbalancedQuoteStaysLiteral() {
        XCTAssertEqual(SecretReference.parse("\"op://v/i/password"),
                       .literal("\"op://v/i/password"))
    }
}

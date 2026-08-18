import XCTest

@testable import MacMobaCore

final class PasteGuardTests: XCTestCase {
    // A single command is the overwhelmingly common paste; prompting for it
    // would train people to click through the prompt they should read.
    func testSingleLineNeedsNoConfirmation() {
        let summary = PasteGuard.inspect("ls -la /var/log")
        XCTAssertFalse(summary.needsConfirmation)
        XCTAssertEqual(summary.lineCount, 1)
    }

    // "Copy the command including its newline" is still one command.
    func testTrailingNewlineIsNotAnExtraLine() {
        let summary = PasteGuard.inspect("make test\n")
        XCTAssertFalse(summary.needsConfirmation)
        XCTAssertEqual(summary.lineCount, 1)
    }

    func testInteriorNewlineNeedsConfirmation() {
        let summary = PasteGuard.inspect("cd /tmp\nrm -rf build\n")
        XCTAssertTrue(summary.needsConfirmation)
        XCTAssertTrue(summary.hasInteriorNewline)
        XCTAssertEqual(summary.lineCount, 2)
    }

    // Text copied from Windows tools, or from some browsers, arrives CRLF.
    func testCRLFAndBareCRCountAsLineBreaks() {
        XCTAssertEqual(PasteGuard.inspect("one\r\ntwo\r\n").lineCount, 2)
        XCTAssertEqual(PasteGuard.inspect("one\rtwo").lineCount, 2)
    }

    // The attack this guards against: a snippet whose visible text is harmless
    // but which carries an escape sequence the terminal, not the shell, acts on.
    func testControlCharactersNeedConfirmation() {
        let summary = PasteGuard.inspect("echo hi\u{1b}[200~")
        XCTAssertTrue(summary.needsConfirmation)
        XCTAssertTrue(summary.hasControlCharacters)
        XCTAssertFalse(summary.hasInteriorNewline)
    }

    func testTabIsNotAControlCharacter() {
        XCTAssertFalse(PasteGuard.inspect("a\tb").hasControlCharacters)
    }

    func testPreviewElidesLongPastesAndHidesEscapes() {
        let summary = PasteGuard.inspect("a\nb\nc\nd\ne\nf")
        XCTAssertTrue(summary.preview.hasPrefix("a\nb\nc\nd\n"))
        XCTAssertTrue(summary.preview.contains("2 more line(s)"))
        XCTAssertFalse(PasteGuard.inspect("x\u{1b}y").preview.contains("\u{1b}"))
    }

    func testPreviewTruncatesWideLines() {
        let summary = PasteGuard.inspect(String(repeating: "x", count: 200) + "\nsecond")
        for line in summary.preview.components(separatedBy: "\n") {
            XCTAssertLessThanOrEqual(line.count, PasteGuard.previewLineWidth + 1)
        }
    }

    func testSingleLineJoinsWithSpacesAndDropsBlanks() {
        XCTAssertEqual(
            PasteGuard.singleLine("cd /tmp\n\n  ls -la  \nexit\n"),
            "cd /tmp ls -la exit"
        )
    }

    func testSingleLineOfSingleLineIsUnchangedApartFromTrim() {
        XCTAssertEqual(PasteGuard.singleLine("uptime\n"), "uptime")
    }
}

import XCTest
@testable import MacMobaCore

/// Telnet option negotiation. Every case here is something that corrupts the
/// session or hangs it if it goes wrong, which is why this is a pure state
/// machine rather than something buried in a socket handler.
final class TelnetProtocolTests: XCTestCase {

    private let iac = TelnetCommand.iac
    private let will = TelnetCommand.will
    private let wont = TelnetCommand.wont
    private let doCmd = TelnetCommand.doCommand
    private let dont = TelnetCommand.dont
    private let sb = TelnetCommand.sb
    private let se = TelnetCommand.se

    // MARK: - Data passthrough

    func testPlainDataPassesThroughUntouched() {
        var telnet = TelnetNegotiator()
        let output = telnet.receive(Array("hello world".utf8))
        XCTAssertEqual(String(decoding: output.terminalData, as: UTF8.self), "hello world")
        XCTAssertTrue(output.reply.isEmpty)
    }

    /// A literal 0xFF in the stream is sent as IAC IAC. Getting this wrong
    /// swallows a byte of real output — invisible until binary data goes past.
    func testEscapedIACBecomesOneLiteralByte() {
        var telnet = TelnetNegotiator()
        let output = telnet.receive([0x41, iac, iac, 0x42])
        XCTAssertEqual(output.terminalData, [0x41, 0xFF, 0x42])
        XCTAssertTrue(output.reply.isEmpty)
    }

    /// Commands can land anywhere, including mid-word, because they arrive in
    /// whatever chunks the network produced.
    func testCommandsAreStrippedFromTheMiddleOfData() {
        var telnet = TelnetNegotiator()
        let output = telnet.receive([0x41, iac, TelnetCommand.nop, 0x42])
        XCTAssertEqual(output.terminalData, [0x41, 0x42])
    }

    /// The real reason this is a state machine: a command can be split across
    /// two reads.
    func testNegotiationSplitAcrossReads() {
        var telnet = TelnetNegotiator()
        XCTAssertEqual(telnet.receive([0x41, iac]).terminalData, [0x41])
        let second = telnet.receive([doCmd, TelnetOption.terminalType])
        XCTAssertTrue(second.terminalData.isEmpty)
        XCTAssertEqual(second.reply, [iac, will, TelnetOption.terminalType])
    }

    // MARK: - Negotiation policy

    func testAgreesToOptionsItSupports() {
        var telnet = TelnetNegotiator()
        XCTAssertEqual(telnet.receive([iac, doCmd, TelnetOption.terminalType]).reply,
                       [iac, will, TelnetOption.terminalType])
        XCTAssertEqual(telnet.receive([iac, will, TelnetOption.echo]).reply,
                       [iac, doCmd, TelnetOption.echo])
        XCTAssertEqual(telnet.receive([iac, will, TelnetOption.suppressGoAhead]).reply,
                       [iac, doCmd, TelnetOption.suppressGoAhead])
    }

    /// Silence is not an acceptable answer to an unknown option — the server
    /// may wait for one. Refusing explicitly keeps the session moving.
    func testRefusesUnknownOptionsExplicitly() {
        var telnet = TelnetNegotiator()
        let unknown: UInt8 = 99
        XCTAssertEqual(telnet.receive([iac, doCmd, unknown]).reply, [iac, wont, unknown])
        XCTAssertEqual(telnet.receive([iac, will, unknown]).reply, [iac, dont, unknown])
    }

    /// The classic Telnet hang: both ends answer every message, so an agreed
    /// option is re-confirmed back and forth until something gives up.
    func testDoesNotLoopWhenAnOptionIsRenegotiated() {
        var telnet = TelnetNegotiator()
        let first = telnet.receive([iac, doCmd, TelnetOption.terminalType])
        XCTAssertFalse(first.reply.isEmpty)

        let repeated = telnet.receive([iac, doCmd, TelnetOption.terminalType])
        XCTAssertTrue(repeated.reply.isEmpty, "re-confirming an agreed option must stay silent")

        let repeatedRefusal = telnet.receive([iac, doCmd, 99])
        XCTAssertFalse(repeatedRefusal.reply.isEmpty)
        XCTAssertTrue(telnet.receive([iac, doCmd, 99]).reply.isEmpty,
                      "re-refusing must stay silent too")
    }

    /// The terminal must not echo locally once the server does, or every
    /// keystroke appears twice.
    func testTracksWhoIsEchoing() {
        var telnet = TelnetNegotiator()
        XCTAssertFalse(telnet.serverEchoes)
        _ = telnet.receive([iac, will, TelnetOption.echo])
        XCTAssertTrue(telnet.serverEchoes)
        _ = telnet.receive([iac, wont, TelnetOption.echo])
        XCTAssertFalse(telnet.serverEchoes)
    }

    // MARK: - Subnegotiation

    func testAnswersTerminalTypeRequest() {
        var telnet = TelnetNegotiator(terminalType: "xterm-256color")
        _ = telnet.receive([iac, doCmd, TelnetOption.terminalType])
        // IAC SB TERMINAL-TYPE SEND IAC SE
        let output = telnet.receive([iac, sb, TelnetOption.terminalType, 1, iac, se])
        var expected: [UInt8] = [iac, sb, TelnetOption.terminalType, 0]
        expected += Array("xterm-256color".utf8)
        expected += [iac, se]
        XCTAssertEqual(output.reply, expected)
        XCTAssertTrue(output.terminalData.isEmpty, "subnegotiation must not reach the terminal")
    }

    /// A server asking for NAWS wants the size straight away; making it wait
    /// for the first resize leaves it rendering for 80x24.
    func testSendsWindowSizeAsSoonAsNAWSIsAgreed() {
        var telnet = TelnetNegotiator(cols: 120, rows: 40)
        let output = telnet.receive([iac, doCmd, TelnetOption.windowSize])
        let expected: [UInt8] = [iac, will, TelnetOption.windowSize,
                                 iac, sb, TelnetOption.windowSize,
                                 0, 120, 0, 40,
                                 iac, se]
        XCTAssertEqual(output.reply, expected)
    }

    func testWindowSizeUpdatesOnlyAfterNAWSIsAgreed() {
        var telnet = TelnetNegotiator()
        XCTAssertTrue(telnet.windowSizeChanged(cols: 100, rows: 30).isEmpty,
                      "must not send NAWS the server never asked for")

        _ = telnet.receive([iac, doCmd, TelnetOption.windowSize])
        XCTAssertEqual(telnet.windowSizeChanged(cols: 100, rows: 30),
                       [iac, sb, TelnetOption.windowSize, 0, 100, 0, 30, iac, se])
    }

    /// A 255-column terminal puts an 0xFF inside the subnegotiation, which
    /// would otherwise read as IAC and truncate the block.
    func testWindowSizeEscapesAByteThatLooksLikeIAC() {
        var telnet = TelnetNegotiator(cols: 255, rows: 24)
        let output = telnet.receive([iac, doCmd, TelnetOption.windowSize])
        let expected: [UInt8] = [iac, will, TelnetOption.windowSize,
                                 iac, sb, TelnetOption.windowSize,
                                 0, 255, 255, 0, 24,
                                 iac, se]
        XCTAssertEqual(output.reply, expected)
    }

    func testSubnegotiationSplitAcrossReadsIsReassembled() {
        var telnet = TelnetNegotiator()
        _ = telnet.receive([iac, doCmd, TelnetOption.terminalType])
        XCTAssertTrue(telnet.receive([iac, sb, TelnetOption.terminalType]).reply.isEmpty)
        let output = telnet.receive([1, iac, se])
        XCTAssertFalse(output.reply.isEmpty, "the reassembled request must still be answered")
    }

    func testUnknownSubnegotiationIsIgnoredNotEchoed() {
        var telnet = TelnetNegotiator()
        let output = telnet.receive([iac, sb, 99, 1, 2, 3, iac, se, 0x41])
        XCTAssertTrue(output.reply.isEmpty)
        XCTAssertEqual(output.terminalData, [0x41], "data after the block must survive")
    }

    // MARK: - Outbound encoding

    func testTypedIACIsEscaped() {
        XCTAssertEqual(TelnetNegotiator.encodeInput([0x41, 0xFF, 0x42]),
                       [0x41, 0xFF, 0xFF, 0x42])
    }

    /// RFC 854 reserves CR LF for "new line", so a bare CR has to be CR NUL.
    /// Servers differ on what they do with a lone CR — some act on it, some
    /// drop it, which shows up as Enter working intermittently.
    func testBareCarriageReturnIsFollowedByNUL() {
        XCTAssertEqual(TelnetNegotiator.encodeInput([0x0D]), [0x0D, 0x00])
        XCTAssertEqual(TelnetNegotiator.encodeInput([0x41, 0x0D]), [0x41, 0x0D, 0x00])
    }

    func testCarriageReturnThatIsAlreadyQualifiedIsLeftAlone() {
        XCTAssertEqual(TelnetNegotiator.encodeInput([0x0D, 0x0A]), [0x0D, 0x0A])
        XCTAssertEqual(TelnetNegotiator.encodeInput([0x0D, 0x00]), [0x0D, 0x00])
    }

    func testEscapeLeavesOrdinaryBytesUntouched() {
        let bytes: [UInt8] = [1, 2, 3]
        XCTAssertEqual(TelnetNegotiator.escape(bytes), bytes)
    }
}

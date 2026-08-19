import XCTest
@testable import MacMobaCore

/// The bug these guard: with a Cangjie/Sucheng input method selected on the
/// laptop, typing into a Screen Sharing session produced nothing usable on the
/// remote Mac — the client was resolving keys through the current input source
/// instead of forwarding the physical key for the remote to compose.
final class ASCIIKeyboardTests: XCTestCase {

    // MARK: - the Carbon lookup

    /// Deliberately layout-agnostic: this asserts the *property* we depend on
    /// (a letter key yields one ASCII letter, and Shift yields its uppercase),
    /// not that the test machine is QWERTY.
    func testLetterKeyYieldsAnASCIILetterWhateverIsSelected() throws {
        let lower = try XCTUnwrap(ASCIIKeyboard.character(forKeyCode: 0, shift: false),
                                  "no ASCII-capable layout available")
        let upper = try XCTUnwrap(ASCIIKeyboard.character(forKeyCode: 0, shift: true))
        XCTAssertEqual(lower.count, 1)
        let scalar = try XCTUnwrap(lower.unicodeScalars.first)
        XCTAssertTrue(("a"..."z").contains(lower) || ("A"..."Z").contains(lower),
                      "expected a letter, got \(lower) (U+\(String(scalar.value, radix: 16)))")
        XCTAssertEqual(upper, lower.uppercased())
    }

    func testSpaceKeyIsSpace() {
        XCTAssertEqual(ASCIIKeyboard.character(forKeyCode: 49, shift: false), " ")
    }

    /// Return carries its own key code; there is nothing printable to forward.
    func testReturnHasNoPrintableCharacter() {
        let returnKey = ASCIIKeyboard.character(forKeyCode: 36, shift: false)
        XCTAssertFalse(RemoteKeyPolicy.sendsPhysicalKey(
            command: false, control: false, option: false, function: false,
            character: returnKey))
    }

    /// The whole point: the answer must not depend on the input source, so two
    /// calls either side of anything the user might do stay equal.
    func testTranslationIsStable() {
        let first = ASCIIKeyboard.character(forKeyCode: 1, shift: false)
        let second = ASCIIKeyboard.character(forKeyCode: 1, shift: false)
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first)
    }

    // MARK: - which keys we take over

    func testPlainTypingIsForwardedAsPhysicalKeys() {
        for character in ["a", "Z", "1", "!", " ", "~"] {
            XCTAssertTrue(sends(character), "\(character) should be forwarded")
        }
    }

    /// Where the remote does not own the modifiers, taking the chords over
    /// would swallow the app's own menu key equivalents.
    func testModifierChordsAreLeftAloneUnlessTheRemoteOwnsThem() {
        XCTAssertFalse(sends("a", command: true))
        XCTAssertFalse(sends("a", control: true))
        XCTAssertFalse(sends("a", option: true))
        XCTAssertFalse(sends("a", function: true), "arrows and F-keys travel by key code")
    }

    /// With a remote desktop focused the library already forwards ⌘ chords to
    /// it, so ⌘C has to be translated like anything else or an input method
    /// decides what the remote receives — which broke copy and paste.
    func testModifierChordsAreTranslatedWhenTheRemoteOwnsThem() {
        for chord in [(command: true, control: false, option: false),
                      (command: false, control: true, option: false),
                      (command: false, control: false, option: true)] {
            XCTAssertTrue(RemoteKeyPolicy.sendsPhysicalKey(
                command: chord.command, control: chord.control, option: chord.option,
                function: false, character: "c", modifiersGoToRemote: true))
        }
        XCTAssertFalse(RemoteKeyPolicy.sendsPhysicalKey(
            command: false, control: false, option: false, function: true,
            character: "c", modifiersGoToRemote: true),
            "the arrows still travel by key code")
    }

    func testShiftAloneStillCountsAsTyping() {
        XCTAssertTrue(RemoteKeyPolicy.sendsPhysicalKey(
            command: false, control: false, option: false, function: false, character: "A"))
    }

    func testUnprintableAndEmptyAreLeftAlone() {
        XCTAssertFalse(sends(nil))
        XCTAssertFalse(sends(""))
        XCTAssertFalse(sends("\r"))
        XCTAssertFalse(sends("\u{1b}"))
        XCTAssertFalse(sends("ab"), "one key, one character")
    }

    /// If the lookup ever hands back a composed character we must not forward
    /// it: the library would send its raw Unicode value as an X11 keysym, which
    /// is exactly the garbage this change exists to stop.
    func testComposedCharactersAreRefused() {
        XCTAssertFalse(sends("日"))
        XCTAssertFalse(sends("ㄅ"))
    }

    private func sends(_ character: String?,
                       command: Bool = false, control: Bool = false,
                       option: Bool = false, function: Bool = false) -> Bool {
        RemoteKeyPolicy.sendsPhysicalKey(command: command, control: control,
                                         option: option, function: function,
                                         character: character)
    }
}

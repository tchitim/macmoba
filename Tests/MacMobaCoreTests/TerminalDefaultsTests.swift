import XCTest
@testable import MacMobaCore

final class TerminalDefaultsTests: XCTestCase {

    /// The library's 500-line default is a widget default; a session manager
    /// that forgets a build log after a few seconds is not doing its job.
    func testTheDefaultIsMoreThanTheLibrarys() {
        XCTAssertGreaterThan(TerminalDefaults.defaultScrollback, 500)
    }

    func testAnUnsetPreferenceGivesTheDefault() {
        let defaults = UserDefaults(suiteName: "scrollback-unset")!
        defaults.removeObject(forKey: TerminalDefaults.scrollbackKey)
        XCTAssertEqual(TerminalDefaults.scrollback(from: defaults),
                       TerminalDefaults.defaultScrollback)
    }

    func testAStoredPreferenceIsUsed() {
        let defaults = UserDefaults(suiteName: "scrollback-set")!
        defaults.set(25_000, forKey: TerminalDefaults.scrollbackKey)
        XCTAssertEqual(TerminalDefaults.scrollback(from: defaults), 25_000)
    }

    /// One pane at two hundred thousand lines is hundreds of megabytes, and a
    /// fleet of them is how an app gets killed for memory.
    func testTheCeilingIsEnforced() {
        XCTAssertEqual(TerminalDefaults.clampedScrollback(5_000_000), 100_000)
        XCTAssertEqual(TerminalDefaults.clampedScrollback(0), 500)
        XCTAssertEqual(TerminalDefaults.clampedScrollback(-1), 500)
    }

    /// A renderer swap should never surprise someone who never asked for it —
    /// if the GPU path ever misbehaves, the people affected opted in.
    func testGPURenderingIsOffUntilAskedFor() {
        let defaults = UserDefaults(suiteName: "metal-unset")!
        // Metal is the default since it was measured at 6-9x the CoreGraphics
        // frame rate; see the comment on usesMetalRenderer.
        defaults.removeObject(forKey: TerminalDefaults.metalRendererKey)
        XCTAssertTrue(TerminalDefaults.usesMetalRenderer(from: defaults))
    }

    func testGPURenderingHonoursBothStoredAnswers() {
        let defaults = UserDefaults(suiteName: "metal-set")!
        defaults.set(true, forKey: TerminalDefaults.metalRendererKey)
        XCTAssertTrue(TerminalDefaults.usesMetalRenderer(from: defaults))
        // Explicitly off must not be read as "unset" and silently re-enabled.
        defaults.set(false, forKey: TerminalDefaults.metalRendererKey)
        XCTAssertFalse(TerminalDefaults.usesMetalRenderer(from: defaults))
    }
}

// MARK: - Which engine a build defaults to

extension TerminalDefaultsTests {
    private func bundleDeclaring(_ value: String?) -> Bundle {
        final class Stub: Bundle, @unchecked Sendable {
            var declared: String?
            override func object(forInfoDictionaryKey key: String) -> Any? {
                key == TerminalDefaults.engineBundleKey ? declared : nil
            }
        }
        let stub = Stub()
        stub.declared = value
        return stub
    }

    /// A build that says nothing is SwiftTerm. This is what every published
    /// release must be, and the reason the plist key is opt-in.
    func testPlainBuildDefaultsToSwiftTerm() {
        let defaults = UserDefaults(suiteName: "engine-plain")!
        defaults.removeObject(forKey: TerminalDefaults.engineKey)
        XCTAssertFalse(TerminalDefaults.usesGhosttyEngine(from: defaults,
                                                          bundle: bundleDeclaring(nil)))
    }

    func testBuildMayDeclareGhostty() {
        let defaults = UserDefaults(suiteName: "engine-declared")!
        defaults.removeObject(forKey: TerminalDefaults.engineKey)
        XCTAssertTrue(TerminalDefaults.usesGhosttyEngine(from: defaults,
                                                         bundle: bundleDeclaring("ghostty")))
    }

    /// The user's own choice outranks the build's, in both directions —
    /// otherwise a libghostty build could not be switched back.
    func testUserChoiceWinsOverTheBuild() {
        let defaults = UserDefaults(suiteName: "engine-override")!
        defaults.set(false, forKey: TerminalDefaults.engineKey)
        XCTAssertFalse(TerminalDefaults.usesGhosttyEngine(from: defaults,
                                                          bundle: bundleDeclaring("ghostty")))
        defaults.set(true, forKey: TerminalDefaults.engineKey)
        XCTAssertTrue(TerminalDefaults.usesGhosttyEngine(from: defaults,
                                                         bundle: bundleDeclaring(nil)))
    }

    /// An unrecognised value is not ghostty. Only the one spelling turns it on.
    func testUnknownDeclarationIsSwiftTerm() {
        let defaults = UserDefaults(suiteName: "engine-unknown")!
        defaults.removeObject(forKey: TerminalDefaults.engineKey)
        XCTAssertFalse(TerminalDefaults.usesGhosttyEngine(from: defaults,
                                                          bundle: bundleDeclaring("swiftterm")))
        XCTAssertFalse(TerminalDefaults.usesGhosttyEngine(from: defaults,
                                                          bundle: bundleDeclaring("")))
    }
}

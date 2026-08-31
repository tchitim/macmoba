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
        defaults.removeObject(forKey: TerminalDefaults.metalRendererKey)
        XCTAssertFalse(TerminalDefaults.usesMetalRenderer(from: defaults))
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

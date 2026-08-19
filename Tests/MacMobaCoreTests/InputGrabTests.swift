import XCTest
@testable import MacMobaCore

final class InputGrabTests: XCTestCase {

    // MARK: - the release gesture

    func testTwoQuickPressesRelease() {
        var gesture = DoubleEscapeRelease(window: 0.5)
        XCTAssertFalse(gesture.escapePressed(at: 10.0), "the first press only arms it")
        XCTAssertTrue(gesture.escapePressed(at: 10.2))
    }

    /// The reason Escape is still usable on the remote: pressing it now and
    /// again while you work must never let go of the keyboard.
    func testPressesFurtherApartThanTheWindowDoNotRelease() {
        var gesture = DoubleEscapeRelease(window: 0.5)
        for time in stride(from: 10.0, to: 20.0, by: 0.9) {
            XCTAssertFalse(gesture.escapePressed(at: time), "released at t=\(time)")
        }
    }

    /// A slow press followed by a quick one still counts — the second press
    /// starts the gesture over rather than being discarded.
    func testASlowPressThenAQuickOneReleases() {
        var gesture = DoubleEscapeRelease(window: 0.5)
        XCTAssertFalse(gesture.escapePressed(at: 10.0))
        XCTAssertFalse(gesture.escapePressed(at: 12.0), "too late to pair with the first")
        XCTAssertTrue(gesture.escapePressed(at: 12.3), "pairs with the second")
    }

    /// Holding Escape (or hammering it) releases once, not on every repeat —
    /// otherwise a burst would toggle the grab back and forth.
    func testARunOfPressesReleasesOnlyOnce() {
        var gesture = DoubleEscapeRelease(window: 0.5)
        let verdicts = [10.0, 10.1, 10.2, 10.3].map { gesture.escapePressed(at: $0) }
        XCTAssertEqual(verdicts, [false, true, false, true])
    }

    func testExactlyAtTheWindowBoundaryCounts() {
        var gesture = DoubleEscapeRelease(window: 0.5)
        XCTAssertFalse(gesture.escapePressed(at: 1.0))
        XCTAssertTrue(gesture.escapePressed(at: 1.5))
    }

    func testResetForgetsAHalfFinishedGesture() {
        var gesture = DoubleEscapeRelease(window: 0.5)
        XCTAssertFalse(gesture.escapePressed(at: 10.0))
        gesture.reset()
        XCTAssertFalse(gesture.escapePressed(at: 10.1), "the armed press was dropped")
    }

    // MARK: - pinning the pointer

    func testPointInsideIsUnchanged() {
        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)
        let point = CGPoint(x: 150, y: 250)
        XCTAssertEqual(PointerClamp.clamp(point, to: rect), point)
    }

    /// maxX and maxY are outside the rectangle, so a clamped point has to stop
    /// short of them — landing exactly on the edge would read as "escaped" and
    /// warp again on every mouse move.
    func testPointsOutsideComeBackInside() {
        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)
        let clamped = PointerClamp.clamp(CGPoint(x: 9_000, y: 9_000), to: rect)
        XCTAssertEqual(clamped, CGPoint(x: 499, y: 499))
        XCTAssertTrue(rect.contains(clamped))

        let low = PointerClamp.clamp(CGPoint(x: -50, y: 0), to: rect)
        XCTAssertEqual(low, CGPoint(x: 100, y: 200))
        XCTAssertTrue(rect.contains(low))
    }

    func testAxesClampIndependently() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(PointerClamp.clamp(CGPoint(x: 50, y: -10), to: rect), CGPoint(x: 50, y: 0))
        XCTAssertEqual(PointerClamp.clamp(CGPoint(x: 200, y: 50), to: rect), CGPoint(x: 99, y: 50))
    }

    func testDegenerateRectIsLeftAlone() {
        let point = CGPoint(x: 5, y: 5)
        XCTAssertEqual(PointerClamp.clamp(point, to: .zero), point)
    }
}

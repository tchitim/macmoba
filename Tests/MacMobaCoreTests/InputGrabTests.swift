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

    // MARK: - the relative pointer

    func testMovementAccumulates() {
        var pointer = RelativePointer(position: CGPoint(x: 100, y: 100),
                                      size: CGSize(width: 1920, height: 1080))
        pointer.move(dx: 10, dy: -5, scale: 1)
        pointer.move(dx: 10, dy: -5, scale: 1)
        XCTAssertEqual(pointer.position, CGPoint(x: 120, y: 90))
    }

    /// A downscaled desktop draws each remote pixel smaller, so the same hand
    /// movement has to cover more of them.
    func testScaleConvertsHandMovementIntoRemotePixels() {
        var pointer = RelativePointer(position: .zero, size: CGSize(width: 1000, height: 1000))
        pointer.move(dx: 100, dy: 100, scale: 0.5)
        XCTAssertEqual(pointer.position, CGPoint(x: 200, y: 200))
    }

    /// The reason position is not rounded as it goes: on a scaled desktop each
    /// event is a fraction of a pixel, and rounding every one of them would
    /// throw slow movement away entirely.
    func testSubPixelMovementIsNotLost() {
        var pointer = RelativePointer(position: .zero, size: CGSize(width: 100, height: 100))
        for _ in 0..<10 { pointer.move(dx: 1, dy: 0, scale: 4) }
        XCTAssertEqual(pointer.position.x, 2.5, accuracy: 0.0001)
        XCTAssertEqual(pointer.framebufferPoint.x, 2)
    }

    func testPointerStopsAtTheEdgesOfTheRemoteScreen() {
        var pointer = RelativePointer(position: CGPoint(x: 10, y: 10),
                                      size: CGSize(width: 800, height: 600))
        pointer.move(dx: -9_999, dy: -9_999, scale: 1)
        XCTAssertEqual(pointer.position, .zero)
        pointer.move(dx: 9_999, dy: 9_999, scale: 1)
        XCTAssertEqual(pointer.position, CGPoint(x: 799, y: 599))
        XCTAssertEqual(pointer.framebufferPoint.x, 799)
        XCTAssertEqual(pointer.framebufferPoint.y, 599)
    }

    func testAStartingPointOutsideTheScreenIsPulledIn() {
        let pointer = RelativePointer(position: CGPoint(x: -40, y: 5_000),
                                      size: CGSize(width: 640, height: 480))
        XCTAssertEqual(pointer.position, CGPoint(x: 0, y: 479))
    }

    /// A zero scale would divide by zero; treat it as 1 rather than producing
    /// an infinite jump.
    func testZeroScaleIsTreatedAsOne() {
        var pointer = RelativePointer(position: .zero, size: CGSize(width: 100, height: 100))
        pointer.move(dx: 5, dy: 5, scale: 0)
        XCTAssertEqual(pointer.position, CGPoint(x: 5, y: 5))
    }

    func testDegenerateRectIsLeftAlone() {
        let point = CGPoint(x: 5, y: 5)
        XCTAssertEqual(PointerClamp.clamp(point, to: .zero), point)
    }
}

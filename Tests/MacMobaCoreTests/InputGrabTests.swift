import XCTest
@testable import MacMobaCore

final class InputGrabTests: XCTestCase {

    // MARK: - the modifier release

    func testHoldingAndReleasingTheChordReleases() {
        var gesture = ModifierChordRelease()
        XCTAssertFalse(gesture.modifiersChanged(held: true), "not until you let go")
        XCTAssertTrue(gesture.modifiersChanged(held: false))
    }

    /// ⌃⌥ plus a letter is a shortcut the remote should receive, not a
    /// half-finished release.
    func testAKeyPressedDuringTheChordCancelsIt() {
        var gesture = ModifierChordRelease()
        _ = gesture.modifiersChanged(held: true)
        gesture.otherKeyPressed()
        XCTAssertFalse(gesture.modifiersChanged(held: false))
    }

    func testLettingGoWithoutHoldingDoesNothing() {
        var gesture = ModifierChordRelease()
        XCTAssertFalse(gesture.modifiersChanged(held: false))
        XCTAssertFalse(gesture.modifiersChanged(held: false))
    }

    /// Releasing once must not leave it armed for the next stray modifier.
    func testTheGestureDisarmsAfterFiring() {
        var gesture = ModifierChordRelease()
        _ = gesture.modifiersChanged(held: true)
        XCTAssertTrue(gesture.modifiersChanged(held: false))
        XCTAssertFalse(gesture.modifiersChanged(held: false))
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
        for _ in 0..<10 { pointer.move(dx: -250, dy: -250, scale: 1) }
        XCTAssertEqual(pointer.position, .zero)
        for _ in 0..<10 { pointer.move(dx: 250, dy: 250, scale: 1) }
        XCTAssertEqual(pointer.position, CGPoint(x: 799, y: 599))
        XCTAssertEqual(pointer.framebufferPoint.x, 799)
        XCTAssertEqual(pointer.framebufferPoint.y, 599)
    }

    /// The jump the user hit: a warp moves the cursor underneath us and the
    /// next report carries that displacement, throwing the pointer across the
    /// screen. Nothing a hand does covers half a screen between two reports.
    func testAnImpossibleSingleStepIsDiscarded() {
        var pointer = RelativePointer(position: CGPoint(x: 400, y: 300),
                                      size: CGSize(width: 800, height: 600))
        pointer.move(dx: 500, dy: 0, scale: 1)
        XCTAssertEqual(pointer.position, CGPoint(x: 400, y: 300), "should have been ignored")
        pointer.move(dx: 0, dy: 400, scale: 1)
        XCTAssertEqual(pointer.position, CGPoint(x: 400, y: 300), "should have been ignored")
    }

    /// The limit is on the step in REMOTE pixels, so a scaled-down window —
    /// where a small hand movement covers a lot of remote screen — is judged on
    /// what it actually does to the pointer.
    func testTheLimitAppliesAfterScaling() {
        var pointer = RelativePointer(position: CGPoint(x: 400, y: 300),
                                      size: CGSize(width: 800, height: 600))
        pointer.move(dx: 100, dy: 0, scale: 0.2)   // 500 remote pixels
        XCTAssertEqual(pointer.position, CGPoint(x: 400, y: 300))
        pointer.move(dx: 100, dy: 0, scale: 1)     // 100 remote pixels, plausible
        XCTAssertEqual(pointer.position, CGPoint(x: 500, y: 300))
    }

    func testOrdinaryFastMovementStillCounts() {
        var pointer = RelativePointer(position: .zero, size: CGSize(width: 1920, height: 1080))
        pointer.move(dx: 300, dy: 200, scale: 1)
        XCTAssertEqual(pointer.position, CGPoint(x: 300, y: 200))
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

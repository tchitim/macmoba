import XCTest

@testable import MacMobaCore

/// Which screen gets which part of the desktop.
///
/// The bug: a window on the built-in display was showing the EXTERNAL
/// monitor's slice, which looks exactly like a wrongly negotiated resolution.
/// Screens were paired to monitors by their position in `NSScreen.screens`,
/// and that array is renumbered whenever a display comes or goes.
final class RDPMonitorIdentityTests: XCTestCase {
    /// A 3840×2160 external above a 3024×2224 built-in — the user's layout,
    /// which produced the 3840×4384 desktop.
    private func layout() -> [RDPMonitor] {
        [RDPMonitor(x: 0, y: 0, width: 3840, height: 2160, isPrimary: true,
                    scalePercent: 100, screenIndex: 0, displayID: 1),
         RDPMonitor(x: 0, y: 2160, width: 3024, height: 2224, isPrimary: false,
                    scalePercent: 200, screenIndex: 1, displayID: 2)]
    }

    func testEachDisplayGetsItsOwnSlice() {
        let monitors = layout()
        XCTAssertEqual(RDPMonitorLayout.monitor(in: monitors, displayID: 2, screenIndex: 1)?.height,
                       2224, "the built-in must show the built-in's part")
        XCTAssertEqual(RDPMonitorLayout.monitor(in: monitors, displayID: 1, screenIndex: 0)?.height,
                       2160)
    }

    /// The regression: the external is unplugged, so the built-in is now
    /// `NSScreen.screens[0]` — the index the EXTERNAL had when the session
    /// connected. Matching by index would hand it the external's 16:9 slice.
    func testUnpluggingADisplayDoesNotShiftSlicesOntoTheWrongScreen() {
        let builtIn = RDPMonitorLayout.monitor(in: layout(), displayID: 2, screenIndex: 0)
        XCTAssertEqual(builtIn?.displayID, 2)
        XCTAssertEqual(builtIn?.height, 2224,
                       "the built-in kept its own slice even though its index changed")
    }

    /// A display plugged in after connecting is in no monitor's layout. Better
    /// no slice — the caller shows the whole desktop — than somebody else's.
    func testAnUnknownDisplayMatchesNothing() {
        XCTAssertNil(RDPMonitorLayout.monitor(in: layout(), displayID: 99, screenIndex: 0))
        XCTAssertNil(RDPMonitorLayout.monitor(in: layout(), displayID: 99, screenIndex: 1),
                     "a known layout must not fall back to index matching")
    }

    /// Only when nothing in the layout has an ID at all is the index all there
    /// is to go on.
    func testIndexIsUsedOnlyWhenNoDisplayIDsAreKnown() {
        let monitors = [
            RDPMonitor(x: 0, y: 0, width: 1920, height: 1080, isPrimary: true, screenIndex: 0),
            RDPMonitor(x: 1920, y: 0, width: 1280, height: 1024, isPrimary: false, screenIndex: 1),
        ]
        XCTAssertEqual(RDPMonitorLayout.monitor(in: monitors, displayID: 0, screenIndex: 1)?.width,
                       1280)
        XCTAssertNil(RDPMonitorLayout.monitor(in: monitors, displayID: 0, screenIndex: 7))
    }

    /// The layout builder must carry the identity through, or none of the above
    /// can work. Sorting puts the primary first, so the array order is not the
    /// screen order either.
    func testDisplayIDsSurviveLayoutConstruction() {
        let screens = [
            RDPMonitorLayout.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    scale: 2, isPrimary: false, displayID: 7),
            RDPMonitorLayout.Screen(frame: CGRect(x: 0, y: 982, width: 1920, height: 1080),
                                    scale: 2, isPrimary: true, displayID: 9),
        ]
        let monitors = RDPMonitorLayout.monitors(for: screens)
        XCTAssertEqual(monitors.count, 2)
        XCTAssertEqual(monitors.first(where: \.isPrimary)?.displayID, 9)
        XCTAssertEqual(RDPMonitorLayout.monitor(in: monitors, displayID: 7,
                                                screenIndex: 0)?.width, 3024)
    }
}

/// Where each monitor's picture sits in the framebuffer.
///
/// RDP puts the primary at (0,0), so anything above or to the left of it has
/// negative coordinates — but the framebuffer has no negative pixels. A laptop
/// with an external screen above it is the ordinary case, and using the raw
/// coordinates there crops the external's slice to nothing.
final class RDPFramebufferRectTests: XCTestCase {
    /// The user's arrangement: 4K external ABOVE a built-in laptop screen,
    /// which is the primary (it has the menu bar).
    private let external = RDPMonitor(x: 0, y: -2160, width: 3840, height: 2160,
                                      isPrimary: false, scalePercent: 100,
                                      screenIndex: 1, displayID: 2)
    private let builtIn = RDPMonitor(x: 0, y: 0, width: 3424, height: 2224,
                                     isPrimary: true, scalePercent: 200,
                                     screenIndex: 0, displayID: 1)

    func testTheScreenAboveThePrimaryStartsAtTheTopOfTheFramebuffer() {
        let layout = [builtIn, external]
        XCTAssertEqual(RDPMonitorLayout.framebufferRect(of: external, in: layout),
                       CGRect(x: 0, y: 0, width: 3840, height: 2160),
                       "a negative y must become the top of the framebuffer, not a crop to nothing")
    }

    func testThePrimaryIsPushedDownByWhateverIsAboveIt() {
        let layout = [builtIn, external]
        XCTAssertEqual(RDPMonitorLayout.framebufferRect(of: builtIn, in: layout),
                       CGRect(x: 0, y: 2160, width: 3424, height: 2224))
    }

    /// Together they must tile the desktop exactly, with no overlap and nothing
    /// outside it.
    func testTheSlicesCoverTheWholeDesktopExactly() {
        let layout = [builtIn, external]
        let size = RDPMonitorLayout.boundingSize(of: layout)
        XCTAssertEqual(size.width, 3840)
        XCTAssertEqual(size.height, 4384)
        let rects = layout.map { RDPMonitorLayout.framebufferRect(of: $0, in: layout) }
        let desktop = CGRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height))
        for rect in rects {
            XCTAssertTrue(desktop.contains(rect), "\(rect) falls outside the desktop")
        }
        XCTAssertFalse(rects[0].intersects(rects[1]))
        XCTAssertEqual(rects.map(\.height).reduce(0, +), desktop.height)
    }

    /// A screen to the LEFT of the primary is the same problem on the x axis.
    func testAScreenLeftOfThePrimaryIsShiftedRight() {
        let left = RDPMonitor(x: -1920, y: 0, width: 1920, height: 1080, isPrimary: false)
        let primary = RDPMonitor(x: 0, y: 0, width: 2560, height: 1080, isPrimary: true)
        let layout = [primary, left]
        XCTAssertEqual(RDPMonitorLayout.framebufferRect(of: left, in: layout),
                       CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(RDPMonitorLayout.framebufferRect(of: primary, in: layout),
                       CGRect(x: 1920, y: 0, width: 2560, height: 1080))
    }

    /// Nothing negative in the layout means nothing moves.
    func testAlreadyPositiveLayoutIsUnchanged() {
        let below = RDPMonitor(x: 0, y: 2160, width: 3024, height: 2224, isPrimary: false)
        let primary = RDPMonitor(x: 0, y: 0, width: 3840, height: 2160, isPrimary: true)
        XCTAssertEqual(RDPMonitorLayout.framebufferRect(of: below, in: [primary, below]),
                       CGRect(x: 0, y: 2160, width: 3024, height: 2224))
    }
}

import XCTest

@testable import MacMobaCore

/// The black-screen bug: a spanning session follows the window like any other
/// fit-to-window session, so it asked the server to resize the desktop to one
/// pane. The display-control request carries a single rectangle, so the
/// multi-monitor desktop collapsed to that size — and every monitor at a
/// non-zero offset then sat outside the framebuffer, painting its screen black.
final class RDPResizePolicyTests: XCTestCase {
    func testFitToWindowOnOneScreenMayResize() {
        XCTAssertTrue(RDPResizePolicy.allowsDynamicResize(spansDisplays: false,
                                                          fitsWindow: true))
    }

    func testFixedSizeNeverResizes() {
        XCTAssertFalse(RDPResizePolicy.allowsDynamicResize(spansDisplays: false,
                                                           fitsWindow: false))
    }

    /// The regression itself.
    func testSpanningSessionNeverResizes() {
        XCTAssertFalse(RDPResizePolicy.allowsDynamicResize(spansDisplays: true,
                                                           fitsWindow: true),
                       "a spanning desktop must stay at the monitor layout's size")
        XCTAssertFalse(RDPResizePolicy.allowsDynamicResize(spansDisplays: true,
                                                           fitsWindow: false))
    }

    // MARK: - Which pixels a screen shows

    func testNoSliceMeansTheWholeDesktop() {
        XCTAssertNil(RDPResizePolicy.visibleSlice(nil, in: CGSize(width: 1920, height: 1080)))
    }

    func testSliceInsideTheDesktopIsKept() {
        let slice = CGRect(x: 0, y: 2160, width: 3840, height: 2224)
        XCTAssertEqual(RDPResizePolicy.visibleSlice(slice,
                                                    in: CGSize(width: 3840, height: 4384)),
                       slice)
    }

    /// The exact shape of the bug: the desktop shrank to one screen, so the
    /// second monitor's rectangle starts past the bottom of the framebuffer.
    /// That must fall back to the whole frame, not to nothing.
    func testSliceEntirelyOutsideTheDesktopFallsBackToTheWholeFrame() {
        let below = CGRect(x: 0, y: 2160, width: 3840, height: 2224)
        XCTAssertNil(RDPResizePolicy.visibleSlice(below,
                                                  in: CGSize(width: 3024, height: 1964)),
                     "an unreachable slice must show the whole desktop, never black")
    }

    func testPartlyOutsideSliceIsClipped() {
        let slice = CGRect(x: 0, y: 1000, width: 3840, height: 2000)
        XCTAssertEqual(RDPResizePolicy.visibleSlice(slice,
                                                    in: CGSize(width: 3840, height: 2160)),
                       CGRect(x: 0, y: 1000, width: 3840, height: 1160))
    }

    /// No frame yet: nothing to slice out of.
    func testEmptyDesktopHasNoSlice() {
        XCTAssertNil(RDPResizePolicy.visibleSlice(CGRect(x: 0, y: 0, width: 100, height: 100),
                                                  in: .zero))
    }

    /// A sliver too thin to crop counts as unreachable rather than as a
    /// zero-width image, which CGImage.cropping would refuse anyway.
    func testSubPixelOverlapCountsAsUnreachable() {
        let slice = CGRect(x: 3839.5, y: 0, width: 1920, height: 1080)
        XCTAssertNil(RDPResizePolicy.visibleSlice(slice,
                                                  in: CGSize(width: 3840, height: 2160)))
    }
}

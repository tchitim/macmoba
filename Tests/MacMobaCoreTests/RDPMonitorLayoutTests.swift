import XCTest
@testable import MacMobaCore

/// Converting macOS screens into RDP monitor definitions.
///
/// This is deliberately testable without any displays attached: the machine
/// this was written on has one screen, and the arrangements that break the
/// conversion — a display above the primary, or to its left — cannot be
/// produced on demand.
final class RDPMonitorLayoutTests: XCTestCase {

    private func screen(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                        scale: CGFloat = 1, primary: Bool = false) -> RDPMonitorLayout.Screen {
        RDPMonitorLayout.Screen(frame: CGRect(x: x, y: y, width: w, height: h),
                                scale: scale, isPrimary: primary)
    }

    func testSingleScreenSitsAtTheOrigin() {
        let monitors = RDPMonitorLayout.monitors(for: [screen(0, 0, 1920, 1080, primary: true)])
        XCTAssertEqual(monitors, [RDPMonitor(x: 0, y: 0, width: 1920, height: 1080,
                                             isPrimary: true, scalePercent: 100)])
        XCTAssertTrue(RDPMonitorLayout.isUsable(monitors))
    }

    func testSecondScreenToTheRight() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1920, 1080, primary: true),
            screen(1920, 0, 1280, 1024),
        ])
        XCTAssertEqual(monitors.count, 2)
        XCTAssertEqual(monitors[0].x, 0)
        XCTAssertEqual(monitors[1].x, 1920)
        // Both sit on y=0 in macOS terms, but macOS aligns them by their BOTTOM
        // edges. The shorter screen's top edge is therefore 1080-1024 = 56
        // lower, and RDP measures from the top.
        XCTAssertEqual(monitors[1].y, 56)
        XCTAssertTrue(RDPMonitorLayout.isUsable(monitors))
    }

    /// Equal heights are the case where the two systems happen to agree.
    func testEqualHeightScreensShareATopEdge() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1920, 1080, primary: true),
            screen(1920, 0, 1920, 1080),
        ])
        XCTAssertEqual(monitors[1].y, 0)
    }

    /// The case the coordinate flip exists for. On macOS a screen physically
    /// ABOVE the primary has a positive y; in RDP it must be negative.
    func testScreenAboveThePrimaryGetsANegativeY() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1920, 1080, primary: true),
            screen(0, 1080, 1920, 1080),
        ])
        let above = monitors.first { !$0.isPrimary }
        XCTAssertEqual(above?.y, -1080,
                       "a screen above the primary must be at a negative y in RDP space")
        XCTAssertEqual(above?.x, 0)
    }

    /// And a screen physically below the primary must be positive.
    func testScreenBelowThePrimaryGetsAPositiveY() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1920, 1080, primary: true),
            screen(0, -1080, 1920, 1080),
        ])
        XCTAssertEqual(monitors.first { !$0.isPrimary }?.y, 1080)
    }

    func testScreenToTheLeftGetsANegativeX() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1920, 1080, primary: true),
            screen(-1280, 0, 1280, 1080),
        ])
        XCTAssertEqual(monitors.first { !$0.isPrimary }?.x, -1280)
    }

    /// Screens of different heights share a bottom edge on macOS, so their top
    /// edges differ — which is where a naive conversion misplaces them.
    func testDifferentHeightsAlignOnTheTopEdgeInRDPSpace() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1920, 1080, primary: true),
            screen(1920, 0, 1280, 800),
        ])
        let secondary = monitors.first { !$0.isPrimary }
        // Its top edge is 280pt below the primary's top edge.
        XCTAssertEqual(secondary?.y, 280)
    }

    func testRetinaScreenIsReportedInPixels() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1512, 982, scale: 2, primary: true)
        ])
        XCTAssertEqual(monitors[0].width, 3024)
        XCTAssertEqual(monitors[0].height, 1964)
        XCTAssertEqual(monitors[0].scalePercent, 200)
    }

    /// This previously asserted x == 1512, which encoded the bug: it scaled the
    /// offset by the *secondary's* factor. The primary is 1512pt at 2x, so it
    /// occupies 3024 pixels and its neighbour must start there. Getting this
    /// wrong left a gap and the server refused the connection outright.
    func testMixedScaleNeighbourStartsWhereThePrimaryEnds() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1512, 982, scale: 2, primary: true),
            screen(1512, 0, 1920, 1080, scale: 1),
        ])
        let primary = monitors.first { $0.isPrimary }
        let secondary = monitors.first { !$0.isPrimary }
        XCTAssertEqual(primary?.width, 3024)
        XCTAssertEqual(secondary?.x, 3024, "must be flush against the primary, not overlapping it")
        XCTAssertEqual(secondary?.width, 1920, "sizes stay each display's own pixel count")
        XCTAssertFalse(RDPMonitorLayout.hasGaps(monitors))
    }

    func testPrimaryComesFirst() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(-1920, 0, 1920, 1080),
            screen(0, 0, 1920, 1080, primary: true),
        ])
        XCTAssertTrue(monitors.first?.isPrimary == true)
        XCTAssertEqual(monitors.first?.x, 0)
        XCTAssertEqual(monitors.first?.y, 0)
    }

    func testWidthsAreEven() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1367, 769, primary: true)
        ])
        XCTAssertEqual(monitors[0].width % 2, 0)
        XCTAssertEqual(monitors[0].height % 2, 0)
        XCTAssertLessThanOrEqual(monitors[0].width, 1367, "must not claim space that is not there")
    }

    // MARK: - Bounding box

    func testBoundingBoxSpansEveryMonitor() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1920, 1080, primary: true),
            screen(1920, 0, 1280, 1024),
        ])
        let size = RDPMonitorLayout.boundingSize(of: monitors)
        XCTAssertEqual(size.width, 3200)
        XCTAssertEqual(size.height, 1080, "the taller monitor sets the height")
    }

    /// With a screen above the primary the origin is negative, so the height is
    /// a span rather than a maximum — this is where "sum the widths" goes wrong.
    func testBoundingBoxAccountsForNegativeOrigins() {
        let monitors = RDPMonitorLayout.monitors(for: [
            screen(0, 0, 1920, 1080, primary: true),
            screen(0, 1080, 1920, 1080),
        ])
        let size = RDPMonitorLayout.boundingSize(of: monitors)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 2160)
    }

    // MARK: - Validation

    func testRejectsLayoutsAServerWouldRefuse() {
        XCTAssertFalse(RDPMonitorLayout.isUsable([]), "empty")

        XCTAssertFalse(RDPMonitorLayout.isUsable([
            RDPMonitor(x: 0, y: 0, width: 1920, height: 1080, isPrimary: false)
        ]), "no primary")

        XCTAssertFalse(RDPMonitorLayout.isUsable([
            RDPMonitor(x: 0, y: 0, width: 1920, height: 1080, isPrimary: true),
            RDPMonitor(x: 1920, y: 0, width: 1280, height: 1024, isPrimary: true),
        ]), "two primaries")

        XCTAssertFalse(RDPMonitorLayout.isUsable([
            RDPMonitor(x: 100, y: 0, width: 1920, height: 1080, isPrimary: true)
        ]), "primary not at the origin")

        XCTAssertFalse(RDPMonitorLayout.isUsable([
            RDPMonitor(x: 0, y: 0, width: 1920, height: 1080, isPrimary: true),
            RDPMonitor(x: 1000, y: 0, width: 1280, height: 1024, isPrimary: false),
        ]), "overlapping monitors")

        XCTAssertFalse(RDPMonitorLayout.isUsable([
            RDPMonitor(x: 0, y: 0, width: 0, height: 1080, isPrimary: true)
        ]), "zero width")
    }

    func testAcceptsAdjacentButNotOverlappingMonitors() {
        XCTAssertTrue(RDPMonitorLayout.isUsable([
            RDPMonitor(x: 0, y: 0, width: 1920, height: 1080, isPrimary: true),
            RDPMonitor(x: 1920, y: 0, width: 1280, height: 1024, isPrimary: false),
        ]), "touching edges is not overlapping")
    }

    /// No primary means no layout — better a normal single-monitor session than
    /// one the server rejects during capability exchange.
    func testNoPrimaryProducesNoLayout() {
        XCTAssertTrue(RDPMonitorLayout.monitors(for: [screen(0, 0, 1920, 1080)]).isEmpty)
    }

    func testMoreScreensThanRDPAllowsAreTruncated() {
        var screens = [screen(0, 0, 800, 600, primary: true)]
        for index in 1...20 {
            screens.append(screen(CGFloat(index) * 800, 0, 800, 600))
        }
        let monitors = RDPMonitorLayout.monitors(for: screens)
        XCTAssertEqual(monitors.count, RDPMonitorLayout.maximumMonitors)
        XCTAssertTrue(RDPMonitorLayout.isUsable(monitors))
    }
}

/// The config gate for spanning displays.
final class RDPUseAllDisplaysTests: XCTestCase {

    private func rdp(useAll: Bool?, mode: RDPDisplayMode? = nil) -> SessionConfig {
        SessionConfig(name: "win", host: "h", port: 3389, username: "u", kind: "rdp",
                      rdpDisplayMode: mode?.rawValue, rdpUseAllDisplays: useAll)
    }

    func testDefaultsToOff() {
        XCTAssertFalse(rdp(useAll: nil).usesAllDisplays,
                       "a vault written before this existed must not start spanning")
    }

    func testOnWhenAskedFor() {
        XCTAssertTrue(rdp(useAll: true).usesAllDisplays)
    }

    /// A fixed desktop size is one rectangle by definition, so spanning cannot
    /// apply — and letting both be set would send a monitor layout that
    /// contradicts the requested size.
    func testFixedSizeWins() {
        XCTAssertFalse(rdp(useAll: true, mode: .fixed).usesAllDisplays)
        XCTAssertTrue(rdp(useAll: true, mode: .fitWindow).usesAllDisplays)
    }

    func testSurvivesAVaultRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let vault = Vault(fileURL: dir.appendingPathComponent("vault.json"))
        var data = try vault.create(masterPassword: "testpass")
        data.sessions = [rdp(useAll: true)]
        try vault.save(data)

        let loaded = try Vault(fileURL: dir.appendingPathComponent("vault.json"))
            .unlock(masterPassword: "testpass")
        XCTAssertTrue(loaded.sessions.first?.usesAllDisplays == true)
    }
}

/// Regression tests from a real failure on a MacBook Air with a 4K external
/// display: the connection was refused outright with
///   "Monitor configuration has gaps! Monitor 0 does not have any neighbor"
/// The layout sent was
///   [0] primary {0x0-3840x2160} scale 100
///   [1]         {2180x4320-3420x2224} scale 200
/// — the second monitor 4320px down when the first is only 2160px tall,
/// because each screen's OFFSET had been multiplied by its own scale factor.
final class RDPMonitorLayoutMixedDPITests: XCTestCase {

    /// 4K external at 1x as primary, 2x laptop screen below and to the right.
    private var reportedArrangement: [RDPMonitorLayout.Screen] {
        [
            RDPMonitorLayout.Screen(frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
                                    scale: 1, isPrimary: true),
            RDPMonitorLayout.Screen(frame: CGRect(x: 1090, y: -1112, width: 1710, height: 1112),
                                    scale: 2, isPrimary: false),
        ]
    }

    func testTheReportedArrangementNoLongerHasGaps() {
        let monitors = RDPMonitorLayout.monitors(for: reportedArrangement)
        XCTAssertEqual(monitors.count, 2, "should still describe both displays")
        XCTAssertFalse(RDPMonitorLayout.hasGaps(monitors),
                       "FreeRDP refuses the whole connection over a gap: \(monitors)")
        XCTAssertTrue(RDPMonitorLayout.isUsable(monitors))
    }

    /// The specific number from the log. The laptop screen must not end up
    /// 4320px down from a 2160px-tall primary.
    func testSecondaryIsAdjacentNotFlungAway() {
        let monitors = RDPMonitorLayout.monitors(for: reportedArrangement)
        guard let secondary = monitors.first(where: { !$0.isPrimary }),
              let primary = monitors.first(where: \.isPrimary) else {
            return XCTFail("missing a monitor")
        }
        XCTAssertNotEqual(secondary.y, 4320, "the original bug, exactly")
        XCTAssertLessThanOrEqual(secondary.y, primary.y + primary.height,
                                 "must touch or overlap the primary's bottom edge")
        // Sizes are still each display's own pixel count.
        XCTAssertEqual(secondary.width, 3420)
        XCTAssertEqual(secondary.height, 2224)
        XCTAssertEqual(secondary.scalePercent, 200)
    }

    /// Below in macOS (lower y) must stay below in RDP (greater y).
    func testDirectionIsPreserved() {
        let monitors = RDPMonitorLayout.monitors(for: reportedArrangement)
        let secondary = monitors.first { !$0.isPrimary }
        XCTAssertEqual(secondary?.y, 2160, "directly below the primary")
    }

    func testMixedDPISideBySideIsAlsoAdjacent() {
        let monitors = RDPMonitorLayout.monitors(for: [
            RDPMonitorLayout.Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                    scale: 1, isPrimary: true),
            RDPMonitorLayout.Screen(frame: CGRect(x: 1920, y: 0, width: 1512, height: 982),
                                    scale: 2, isPrimary: false),
        ])
        XCTAssertFalse(RDPMonitorLayout.hasGaps(monitors))
        let secondary = monitors.first { !$0.isPrimary }
        XCTAssertEqual(secondary?.x, 1920, "flush against the primary's right edge")
        XCTAssertEqual(secondary?.width, 3024, "still its own pixel width")
    }

    /// Matching scales still use the true geometry — the snapping is only for
    /// arrangements that cannot be represented exactly.
    func testUniformScaleKeepsExactGeometry() {
        let monitors = RDPMonitorLayout.monitors(for: [
            RDPMonitorLayout.Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                    scale: 1, isPrimary: true),
            RDPMonitorLayout.Screen(frame: CGRect(x: 1920, y: 0, width: 1280, height: 1024),
                                    scale: 1, isPrimary: false),
        ])
        XCTAssertEqual(monitors.first { !$0.isPrimary }?.y, 56,
                       "bottom-aligned screens of different heights keep their real offset")
        XCTAssertFalse(RDPMonitorLayout.hasGaps(monitors))
    }

    /// Three displays, mixed scales — every one must touch something.
    func testThreeDisplaysAllTouch() {
        let monitors = RDPMonitorLayout.monitors(for: [
            RDPMonitorLayout.Screen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                    scale: 1, isPrimary: true),
            RDPMonitorLayout.Screen(frame: CGRect(x: 2560, y: 0, width: 1512, height: 982),
                                    scale: 2, isPrimary: false),
            RDPMonitorLayout.Screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                    scale: 1, isPrimary: false),
        ])
        XCTAssertEqual(monitors.count, 3)
        XCTAssertFalse(RDPMonitorLayout.hasGaps(monitors), "\(monitors)")
        XCTAssertTrue(RDPMonitorLayout.isUsable(monitors))
    }

    /// A layout that cannot be made valid must yield NOTHING, so the session
    /// connects as a single monitor instead of failing to connect at all.
    func testAnImpossibleLayoutFallsBackToSingleMonitor() {
        // No primary at all.
        let monitors = RDPMonitorLayout.monitors(for: [
            RDPMonitorLayout.Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                    scale: 1, isPrimary: false),
            RDPMonitorLayout.Screen(frame: CGRect(x: 5000, y: 5000, width: 1920, height: 1080),
                                    scale: 1, isPrimary: false),
        ])
        XCTAssertTrue(monitors.isEmpty)
    }
}

/// Pairing monitors back to the screens they came from.
///
/// The returned array is sorted with the primary first, so its order does NOT
/// match NSScreen.screens. Pairing by position put the second screen's picture
/// on the wrong display — and, when the indices happened to miss, left a screen
/// black.
final class RDPMonitorScreenIndexTests: XCTestCase {

    private func screen(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                        scale: CGFloat = 1, primary: Bool = false) -> RDPMonitorLayout.Screen {
        RDPMonitorLayout.Screen(frame: CGRect(x: x, y: y, width: w, height: h),
                                scale: scale, isPrimary: primary)
    }

    /// The primary is listed SECOND here, so sorting reorders the result and
    /// position-based pairing would swap the two displays.
    func testIndexSurvivesSorting() {
        let screens = [
            screen(-1920, 0, 1920, 1080),            // screens[0]
            screen(0, 0, 1920, 1080, primary: true), // screens[1]
        ]
        let monitors = RDPMonitorLayout.monitors(for: screens)
        XCTAssertEqual(monitors.first?.isPrimary, true, "primary is sorted to the front")
        XCTAssertEqual(monitors.first?.screenIndex, 1, "but it came from screens[1]")
        XCTAssertEqual(monitors.last?.screenIndex, 0)
    }

    /// Every monitor must point at a distinct, in-range screen — otherwise a
    /// window is built for a screen that does not exist, or two windows fight
    /// over one.
    func testIndicesAreUniqueAndInRange() {
        let screens = [
            screen(0, 0, 2560, 1440, primary: true),
            screen(2560, 0, 1512, 982, scale: 2),
            screen(-1920, 0, 1920, 1080),
        ]
        let monitors = RDPMonitorLayout.monitors(for: screens)
        XCTAssertEqual(monitors.count, 3)
        XCTAssertEqual(Set(monitors.map(\.screenIndex)).count, 3, "indices must be distinct")
        for monitor in monitors {
            XCTAssertTrue((0..<screens.count).contains(monitor.screenIndex))
        }
    }

    /// Mixed DPI goes through the snapping path, which rebuilds the array — the
    /// index has to survive that too.
    func testIndexSurvivesTheMixedDPIPath() {
        let screens = [
            screen(0, 0, 3840, 2160, primary: true),
            screen(1090, -1112, 1710, 1112, scale: 2),
        ]
        let monitors = RDPMonitorLayout.monitors(for: screens)
        let secondary = monitors.first { !$0.isPrimary }
        XCTAssertEqual(secondary?.screenIndex, 1)
        XCTAssertEqual(monitors.first { $0.isPrimary }?.screenIndex, 0)
    }
}

/// Which screen shows what, when the session's own window is NOT on the primary.
///
/// The reported failure: MacMoba running on the second screen. Entering full
/// screen turned that screen black and left the first screen untouched —
/// because the code assumed the window was on the primary, so it covered the
/// session's own display and never gave the other one a window.
final class RDPSpanScreenSelectionTests: XCTestCase {

    private func layout() -> [RDPMonitor] {
        RDPMonitorLayout.monitors(for: [
            RDPMonitorLayout.Screen(frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
                                    scale: 1, isPrimary: true),        // screens[0]
            RDPMonitorLayout.Screen(frame: CGRect(x: 1090, y: -1112, width: 1710, height: 1112),
                                    scale: 2, isPrimary: false),       // screens[1]
        ])
    }

    /// The exact reported case: the window lives on screen 1.
    func testWindowOnTheSecondScreenKeepsThatScreenAndCoversTheOther() {
        let (host, others) = RDPMonitorLayout.split(layout(), hostScreenIndex: 1)
        XCTAssertEqual(host?.screenIndex, 1, "the window's own screen shows its own slice")
        XCTAssertEqual(others.map(\.screenIndex), [0],
                       "the OTHER screen is the one needing a window")
        XCTAssertFalse(others.contains { $0.screenIndex == 1 },
                       "must never put a window over the session's own screen")
    }

    func testWindowOnThePrimaryBehavesTheOldWay() {
        let (host, others) = RDPMonitorLayout.split(layout(), hostScreenIndex: 0)
        XCTAssertEqual(host?.screenIndex, 0)
        XCTAssertEqual(others.map(\.screenIndex), [1])
    }

    /// Whatever the window sits on, every screen must be shown exactly once.
    func testEveryScreenIsCoveredExactlyOnceFromAnyHost() {
        let monitors = RDPMonitorLayout.monitors(for: [
            RDPMonitorLayout.Screen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                    scale: 1, isPrimary: true),
            RDPMonitorLayout.Screen(frame: CGRect(x: 2560, y: 0, width: 1512, height: 982),
                                    scale: 2, isPrimary: false),
            RDPMonitorLayout.Screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                    scale: 1, isPrimary: false),
        ])
        for host in 0..<3 {
            let (hostMonitor, others) = RDPMonitorLayout.split(monitors, hostScreenIndex: host)
            var covered = others.map(\.screenIndex)
            if let hostMonitor { covered.append(hostMonitor.screenIndex) }
            XCTAssertEqual(Set(covered), Set(0..<3), "host \(host) did not cover every screen")
            XCTAssertEqual(covered.count, 3, "host \(host) covered a screen twice")
        }
    }

    /// A stale index (a display unplugged mid-session) must not leave the
    /// session's own window covered.
    func testUnknownHostIndexFallsBackToThePrimary() {
        let (host, others) = RDPMonitorLayout.split(layout(), hostScreenIndex: 99)
        XCTAssertEqual(host?.isPrimary, true)
        XCTAssertFalse(others.contains { $0.isPrimary })
    }
}

import XCTest
@testable import MacMobaCore

/// The points-to-pixels conversion for the RDP desktop size. This is the part
/// that cannot be checked by looking at a 1x development display: the Retina
/// behaviour only shows up in the arithmetic.
final class RDPDesktopSizeTests: XCTestCase {

    func testAsksInPixelsNotPoints() {
        // The bug this covers: asking in points on a Retina display gets a
        // half-resolution desktop that then has to be upscaled to fill the pane.
        let onePoint = RDPDesktopSize.pixels(forPoints: CGSize(width: 800, height: 600),
                                             scale: 1, enforceMinimum: false)
        let twoPoint = RDPDesktopSize.pixels(forPoints: CGSize(width: 800, height: 600),
                                             scale: 2, enforceMinimum: false)
        XCTAssertEqual(onePoint.width, 800)
        XCTAssertEqual(onePoint.height, 600)
        XCTAssertEqual(twoPoint.width, 1600)
        XCTAssertEqual(twoPoint.height, 1200)
    }

    func testWidthIsRoundedDownToMultipleOfFour() {
        // Servers reject widths that are not a multiple of 4.
        for width in [641, 642, 643, 644, 1133, 1920] {
            let size = RDPDesktopSize.pixels(forPoints: CGSize(width: CGFloat(width), height: 600),
                                             scale: 1, enforceMinimum: false)
            XCTAssertEqual(size.width % 4, 0, "\(width) produced \(size.width)")
            XCTAssertLessThanOrEqual(size.width, width,
                                     "rounded up past the pane for \(width)")
            XCTAssertGreaterThan(width - size.width, -1)
            XCTAssertLessThan(width - size.width, 4, "lost more than a rounding step")
        }
    }

    /// A fractional scale (some external displays report 1.5 or similar) still
    /// has to produce a legal width.
    func testFractionalScaleStillProducesALegalWidth() {
        let size = RDPDesktopSize.pixels(forPoints: CGSize(width: 1000, height: 700),
                                         scale: 1.5, enforceMinimum: false)
        XCTAssertEqual(size.width % 4, 0)
        XCTAssertEqual(size.height, 1050)
    }

    func testConnectEnforcesAMinimumButResizeDoesNot() {
        let tiny = CGSize(width: 120, height: 90)
        let connecting = RDPDesktopSize.pixels(forPoints: tiny, scale: 1, enforceMinimum: true)
        XCTAssertEqual(connecting.width, RDPDesktopSize.minimumWidth)
        XCTAssertEqual(connecting.height, RDPDesktopSize.minimumHeight)

        let resizing = RDPDesktopSize.pixels(forPoints: tiny, scale: 1, enforceMinimum: false)
        XCTAssertEqual(resizing.width, 120)
        XCTAssertEqual(resizing.height, 90)
    }

    /// The minimum is in pixels, so a Retina pane that is already big enough
    /// must not be dragged up to it.
    func testMinimumDoesNotOverrideARealRetinaSize() {
        let size = RDPDesktopSize.pixels(forPoints: CGSize(width: 400, height: 300),
                                         scale: 2, enforceMinimum: true)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    /// A pane that has not been laid out yet, and a nonsensical scale, must not
    /// produce something the caller will hand to the server.
    func testDegenerateInputs() {
        let unlaidOut = RDPDesktopSize.pixels(forPoints: .zero, scale: 2, enforceMinimum: true)
        XCTAssertEqual(unlaidOut.width, RDPDesktopSize.minimumWidth)
        XCTAssertEqual(unlaidOut.height, RDPDesktopSize.minimumHeight)

        let zeroScale = RDPDesktopSize.pixels(forPoints: CGSize(width: 800, height: 600),
                                              scale: 0, enforceMinimum: false)
        XCTAssertEqual(zeroScale.width, 800, "a zero scale must fall back to 1, not collapse")
        XCTAssertEqual(zeroScale.height, 600)

        let negative = RDPDesktopSize.pixels(forPoints: CGSize(width: -10, height: -10),
                                             scale: 1, enforceMinimum: false)
        XCTAssertEqual(negative.width, 0)
        XCTAssertEqual(negative.height, 0)
    }
}

/// Per-session display mode: fit the window, or pin one desktop size.
final class RDPDisplayModeTests: XCTestCase {

    private func rdpSession(mode: RDPDisplayMode?, width: Int? = nil,
                            height: Int? = nil) -> SessionConfig {
        SessionConfig(name: "win", host: "h", port: 3389, username: "u",
                      kind: "rdp", rdpDisplayMode: mode?.rawValue,
                      rdpWidth: width, rdpHeight: height)
    }

    /// A vault written before these fields existed has to keep working, and
    /// "no opinion" must mean the behaviour people already had.
    func testDefaultsToFittingTheWindow() {
        XCTAssertEqual(rdpSession(mode: nil).displayMode, .fitWindow)
        XCTAssertNil(rdpSession(mode: nil).fixedDesktopSize,
                     "fitting the window must not pin a size")

        var legacy = rdpSession(mode: nil)
        legacy.rdpDisplayMode = "something we do not know"
        XCTAssertEqual(legacy.displayMode, .fitWindow)
    }

    func testFixedModeReportsItsSize() {
        let size = rdpSession(mode: .fixed, width: 1600, height: 900).fixedDesktopSize
        XCTAssertEqual(size?.width, 1600)
        XCTAssertEqual(size?.height, 900)
    }

    /// The editor lets a width be typed, so it can be anything at all.
    func testFixedSizeIsClampedToSomethingSendable() {
        let tiny = rdpSession(mode: .fixed, width: 10, height: 10).fixedDesktopSize
        XCTAssertEqual(tiny?.width, RDPDesktopSize.minimumWidth)
        XCTAssertEqual(tiny?.height, RDPDesktopSize.minimumHeight)

        let odd = rdpSession(mode: .fixed, width: 1919, height: 1080).fixedDesktopSize
        XCTAssertEqual(odd?.width, 1916, "width must stay a multiple of 4")
    }

    func testFixedModeWithNoSizeFallsBackToAUsableDefault() {
        let size = rdpSession(mode: .fixed).fixedDesktopSize
        XCTAssertEqual(size?.width, 1920)
        XCTAssertEqual(size?.height, 1080)
    }

    /// The whole point of the setting is that it survives being saved.
    func testSurvivesAVaultRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let vault = Vault(fileURL: dir.appendingPathComponent("vault.json"))
        var data = try vault.create(masterPassword: "hunter2")
        data.sessions = [rdpSession(mode: .fixed, width: 1600, height: 900)]
        try vault.save(data)

        let reopened = Vault(fileURL: dir.appendingPathComponent("vault.json"))
        let loaded = try reopened.unlock(masterPassword: "hunter2")
        XCTAssertEqual(loaded.sessions.first?.displayMode, .fixed)
        XCTAssertEqual(loaded.sessions.first?.fixedDesktopSize?.width, 1600)
        XCTAssertEqual(loaded.sessions.first?.fixedDesktopSize?.height, 900)
    }
}

/// Never ask a server for a desktop bigger than the display can show.
///
/// Extra pixels beyond the screen are pure cost: the picture is scaled down to
/// fit, so the detail is discarded and everything just ends up smaller.
final class RDPDesktopSizeScreenCapTests: XCTestCase {

    private let screen1440p = CGSize(width: 2560, height: 1440)

    func testFitToWindowIsCappedToTheScreen() {
        // A pane larger than the screen cannot happen in practice, but the
        // scale multiply can push the request past it on a Retina display.
        let size = RDPDesktopSize.pixels(forPoints: CGSize(width: 2000, height: 1300),
                                         scale: 2, enforceMinimum: true,
                                         screenPixels: screen1440p)
        XCTAssertEqual(size.width, 2560)
        XCTAssertEqual(size.height, 1440)
    }

    func testASizeThatFitsIsLeftAlone() {
        let size = RDPDesktopSize.pixels(forPoints: CGSize(width: 1280, height: 800),
                                         scale: 1, enforceMinimum: true,
                                         screenPixels: screen1440p)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 800)
    }

    /// A fixed size is typed by hand and checked against nothing, so this is
    /// where an oversized request actually comes from.
    func testFixedSizeIsCappedToTheScreen() {
        let capped = RDPDesktopSize.capped((width: 3840, height: 2160),
                                           toScreenPixels: screen1440p)
        XCTAssertEqual(capped.width, 2560)
        XCTAssertEqual(capped.height, 1440)
    }

    func testFixedSizeSmallerThanTheScreenIsUntouched() {
        let capped = RDPDesktopSize.capped((width: 1920, height: 1080),
                                           toScreenPixels: screen1440p)
        XCTAssertEqual(capped.width, 1920)
        XCTAssertEqual(capped.height, 1080)
    }

    /// Spanning displays passes nil: exceeding one screen is the entire point.
    func testNoCapWhenNoScreenIsGiven() {
        let size = RDPDesktopSize.pixels(forPoints: CGSize(width: 3840, height: 4384),
                                         scale: 1, enforceMinimum: true, screenPixels: nil)
        XCTAssertEqual(size.width, 3840)
        XCTAssertEqual(size.height, 4384)

        let capped = RDPDesktopSize.capped((width: 3840, height: 4384), toScreenPixels: nil)
        XCTAssertEqual(capped.width, 3840)
        XCTAssertEqual(capped.height, 4384)
    }

    /// The cap must not produce something a server refuses.
    func testCappedSizesStayLegal() {
        for screen in [CGSize(width: 1366, height: 768), CGSize(width: 3023, height: 1963)] {
            let size = RDPDesktopSize.pixels(forPoints: CGSize(width: 9999, height: 9999),
                                             scale: 1, enforceMinimum: true,
                                             screenPixels: screen)
            XCTAssertEqual(size.width % 4, 0, "width must stay a multiple of 4")
            XCTAssertLessThanOrEqual(size.width, Int(screen.width))
            XCTAssertLessThanOrEqual(size.height, Int(screen.height))
            XCTAssertGreaterThanOrEqual(size.width, RDPDesktopSize.minimumWidth)

            let capped = RDPDesktopSize.capped((width: 9999, height: 9999),
                                               toScreenPixels: screen)
            XCTAssertEqual(capped.width % 4, 0)
            XCTAssertLessThanOrEqual(capped.width, Int(screen.width))
        }
    }

    /// A screen smaller than the minimum must not yield an illegal desktop.
    func testMinimumWinsOverAnAbsurdlySmallScreen() {
        let capped = RDPDesktopSize.capped((width: 1920, height: 1080),
                                           toScreenPixels: CGSize(width: 100, height: 100))
        XCTAssertEqual(capped.width, RDPDesktopSize.minimumWidth)
        XCTAssertEqual(capped.height, RDPDesktopSize.minimumHeight)
    }
}

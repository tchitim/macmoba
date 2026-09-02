// libghostty behind the same seam SwiftTerm sits behind.
//
// This is what lets an ordinary SSH or local-shell pane be drawn by libghostty
// instead: `TerminalTab` and `LocalTerminalTab` talk to `TerminalEngineView`
// and never learn which one they got.
//
// WHY IT HOSTS A SWIFTUI VIEW RATHER THAN BUILDING AN NSVIEW. An earlier
// attempt handed the package's AppKit `TerminalView` to a hand-written
// container and it silently did nothing — the shell started, but no keystroke
// arrived and the PTY stayed at its default size. The package's own
// representable does two things that container did not: it sets the view's
// delegate to the view state, and it assigns `attachedView`, which is what
// makes `requestFocus()` able to find anything. `attachedView` is internal to
// the package, so reimplementing that from here is not possible — and would be
// the wrong instinct anyway, since it means maintaining a copy of somebody
// else's lifecycle. Hosting their tested view is both simpler and correct.

import AppKit
import Combine
import Foundation
import GhosttyTerminal
import MacMobaCore
import SwiftUI

@MainActor
final class GhosttyEngine: NSObject, TerminalEngineView {
    var engineOnInput: ((ArraySlice<UInt8>) -> Void)?
    var engineOnResize: ((Int, Int) -> Void)?
    var engineOnTitle: ((String) -> Void)?
    var engineOnBell: (() -> Void)?
    var engineOnOpenLink: ((String) -> Void)?
    var engineOnClipboardCopy: ((Data) -> Void)?

    let surfaceState = GhosttyControllerConfig.makeState()
    private let session: InMemoryTerminalSession
    private var titleObservation: AnyCancellable?
    private var bellObservation: AnyCancellable?

    private lazy var hosting: NSHostingView<TerminalSurfaceView> = {
        let host = NSHostingView(rootView: TerminalSurfaceView(context: surfaceState))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        return host
    }()

    override init() {
        // libghostty calls these from its own terminal IO thread, so nothing
        // here may assume the main actor — asserting it aborts the process,
        // which is how the first version of the experimental pane died.
        var deliverInput: ((Data) -> Void)?
        var deliverResize: ((Int, Int) -> Void)?
        session = InMemoryTerminalSession(
            write: { data in deliverInput?(data) },
            resize: { port in deliverResize?(Int(port.columns), Int(port.rows)) },
            // This host repaints per dispatch and reads only rows and columns,
            // which is the case the flag exists for.
            suppressesPixelOnlyResizes: true
        )
        super.init()
        deliverInput = { [weak self] data in
            Task { @MainActor in self?.engineOnInput?(ArraySlice(data)) }
        }
        deliverResize = { [weak self] cols, rows in
            Task { @MainActor in self?.engineOnResize?(cols, rows) }
        }
        surfaceState.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

        titleObservation = surfaceState.$title.sink { [weak self] title in
            Task { @MainActor in self?.engineOnTitle?(title) }
        }
        // The package counts bells rather than announcing them, so a change in
        // the count is the event.
        bellObservation = surfaceState.$bellCount.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.engineOnBell?() }
        }
    }

    var engineView: NSView { hosting }

    func engineFeed(_ bytes: ArraySlice<UInt8>) { session.receive(Data(bytes)) }

    var engineGrid: (cols: Int, rows: Int) {
        guard let metrics = surfaceState.surfaceSize else { return (80, 24) }
        let cols = Int(metrics.columns), rows = Int(metrics.rows)
        return cols > 0 && rows > 0 ? (cols, rows) : (80, 24)
    }

    /// Applied when the controller is built, not here.
    ///
    /// libghostty takes scrollback as a config value in BYTES and applies it to
    /// new surfaces only — its own documentation says a change "will only
    /// affect new terminal surfaces". `GhosttyControllerConfig` already reads
    /// the same user setting SwiftTerm does, so a pane opened after a change
    /// gets it; this is a no-op rather than a lie about being able to resize a
    /// live buffer.
    func engineSetScrollback(_ lines: Int) {}

    func engineSetFontSize(_ size: Double) {
        // Deliberately unimplemented for now: font size is a controller config
        // value here, not a property of the view, so changing it means
        // rebuilding the controller and with it the surface — which would
        // discard the scrollback. Wiring it properly is part of restoring the
        // view-level settings, and doing it badly would silently clear panes.
    }

    func engineSelection() -> String? {
        guard let surface = surfaceState.surface, surface.hasSelection() else { return nil }
        return surface.readSelection()
    }

    func engineSelectAll() {
        // No select-all in the package's surface API. `readViewportText` gets
        // the text but cannot make a visible selection, so claiming this works
        // would give a Select All menu item that appears to do nothing.
    }

    func engineScroll(toRow row: Int) {
        _ = surfaceState.scrollToRow(UInt(max(0, row)))
    }

    /// Viewport only, not the whole scrollback.
    ///
    /// `readViewportText` is what the package exposes. SwiftTerm's version of
    /// this walks the scroll-invariant rows and returns history too, so
    /// `read-screen` and the session log's pre-logging header see less here.
    /// Named rather than quietly different.
    func engineDumpText() -> String { session.readViewportText() ?? "" }

    var engineHasKeyboardFocus: Bool { surfaceState.isFocused }

    /// Through the view state, which is the only thing that knows where the
    /// surface ended up inside the hosted SwiftUI view.
    func engineTakeFocus() { surfaceState.requestFocus() }
}

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

    /// libghostty's view, subclassed only to replace its context menu.
    ///
    /// `selectionContextMenu()` is `open` and offers Copy alone; MacMoba's has
    /// Paste and Paste as One Line too, and paste-as-one-line is the reason the
    /// app has its own in the first place. `menu(for:)` is overridden as well
    /// so a right-click outside the selection still gets a menu — the
    /// package returns none there.
    private final class MenuTerminalView: GhosttyTerminal.TerminalView {
        weak var menuTarget: ClipboardMenuTarget?
        override func menu(for event: NSEvent) -> NSMenu? { menuTarget?.menu() }
        override func selectionContextMenu() -> NSMenu {
            menuTarget?.menu() ?? super.selectionContextMenu()
        }

        /// Says which Edit-menu items apply here — which is what makes ⌘V work
        /// at all.
        ///
        /// AppKit validates a menu item before letting its shortcut fire, and
        /// asks the first responder. SwiftTerm's view answers (its
        /// `validateUserInterfaceItem` enables Paste); the libghostty view
        /// implements no validation whatsoever, so Edit ▸ Paste stayed
        /// disabled and ⌘V silently did nothing. Typing was unaffected,
        /// because key events reach the view directly without passing through
        /// menu validation — which is exactly why "cannot paste text" arrived
        /// with everything else working.
        /// Implemented, not overridden: the superclass has no validation of
        /// any kind, which is the whole problem. `surface` is internal to the
        /// package, so Copy's enablement asks the view state instead.
        weak var state: TerminalViewState?

        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            switch item.action {
            case Selector(("paste:")):
                let has = NSPasteboard.general.canReadObject(
                    forClasses: [NSString.self], options: nil)
                PasteTrace.log("validate paste: -> \(has ? "enabled" : "no text on clipboard")")
                return has
            case Selector(("copy:")):
                return state?.surface?.hasSelection() ?? false
            case Selector(("selectAll:")):
                // The action exists on the view but the surface API behind it
                // does nothing, so an enabled item would be a lie.
                return false
            default:
                // Anything else is not this view's business; leaving it
                // enabled keeps the rest of the Edit menu behaving as it did.
                return true
            }
        }
    }

    private var menuTarget: ClipboardMenuTarget?

    /// Turns the package's own input/output logging on when asked.
    ///
    /// Exists because "paste does nothing" cannot be diagnosed from outside:
    /// the paste either reaches the surface or it does not, and both look
    /// identical. The accessibility automation this session used to drive the
    /// app stopped working, so the only way to see inside is from the machine
    /// where it happens.
    ///
    ///     defaults write dev.macmoba.MacMoba ghosttyDebugLog -bool true
    ///     log stream --predicate 'process == "MacMoba"' | grep ghostty
    /// Checked on every pane, not once: the first version ran a single time
    /// on the first pane ever built, so turning the default on and opening a
    /// new tab did nothing — which is how it produced no output at all when
    /// it was needed.
    static func configureDebugLoggingIfAsked() {
        guard PasteTrace.enabled else { return }
        TerminalDebugLog.sink = { message in NSLog("ghostty: %@", message) }
        TerminalDebugLog.enable([.input, .output, .lifecycle])
    }

    override init() {
        Self.configureDebugLoggingIfAsked()
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
        // The package builds its platform view through this hook, which is how
        // the subclass gets in without reimplementing the representable.
        let target = ClipboardMenuTarget(engine: self)
        menuTarget = target
        let viewState = surfaceState
        surfaceState.makePlatformView = {
            let view = MenuTerminalView(frame: .zero)
            view.menuTarget = target
            view.state = viewState
            return view
        }

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

    var engineName: String { "libghostty" }

    func engineFeed(_ bytes: ArraySlice<UInt8>) { session.receive(Data(bytes)) }

    func engineSendText(_ text: String) { _ = surfaceState.surface?.sendText(text) }

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
        fontSize = size
        pushConfiguration()
    }

    func engineApplyTheme(_ theme: AppTerminalTheme) {
        // libghostty takes colours as config text, so the app's hex strings go
        // in almost unchanged — no 16-bit channel conversion like SwiftTerm's.
        // Light and dark get the same values because MacMoba's themes are
        // absolute rather than adaptive; handing only one would leave the other
        // appearance on ghostty's defaults.
        let config = GhosttyTerminal.TerminalConfiguration { builder in
            builder.withCustom("background", theme.background)
            builder.withCustom("foreground", theme.foreground)
            builder.withCustom("cursor-color", theme.cursor)
            for (index, hex) in theme.ansi.enumerated() {
                builder.withCustom("palette", "\(index)=\(hex)")
            }
        }
        let scheme = GhosttyTerminal.TerminalTheme(light: config, dark: config)
        _ = surfaceState.controller.setTheme(scheme)
    }

    private var fontSize: Double = 0

    /// Font size is a config value here rather than a view property, and the
    /// controller applies config changes to the live surface, so this keeps
    /// the scrollback.
    private func pushConfiguration() {
        guard fontSize > 0 else { return }
        let config = GhosttyTerminal.TerminalConfiguration { builder in
            builder.withCustom("font-size", String(Int(fontSize.rounded())))
        }
        _ = surfaceState.controller.setTerminalConfiguration(config)
    }

    func engineSelection() -> String? {
        guard let surface = surfaceState.surface, surface.hasSelection() else { return nil }
        return surface.readSelection()
    }

    var engineHasSelection: Bool { surfaceState.surface?.hasSelection() ?? false }

    /// No select-all in the package's surface API, so the menu leaves the item
    /// out rather than offering one that does nothing.
    var engineCanSelectAll: Bool { false }

    func engineSelectAll() {}

    /// libghostty frames the paste itself — a program that asked for bracketed
    /// paste receives it framed — so this is one call where SwiftTerm needs
    /// the escape sequences added by hand.
    func enginePaste(_ text: String) {
        let accepted = surfaceState.paste(text: text)
        PasteTrace.log("enginePaste \(text.count) chars -> "
                       + "\(accepted ? "accepted" : "REFUSED by surface")"
                       + ", surface=\(surfaceState.surface == nil ? "nil" : "attached")")
    }

    func engineScroll(toRow row: Int) {
        _ = surfaceState.scrollToRow(UInt(max(0, row)))
    }

    /// Scrollback included, matching SwiftTerm's version.
    ///
    /// This was the viewport only while `readViewportText` was all the package
    /// offered. libghostty can read any range, so `readAllText` was added to
    /// the vendored copy and this is no longer the lesser of the two.
    ///
    /// Rows are numbered from zero at the top of the scrollback, which is what
    /// `scrollToRow` takes, so the index is the row.
    func engineTextLines() -> [(row: Int, text: String)] {
        let text = surfaceState.readAllText() ?? session.readViewportText() ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { ($0.offset, String($0.element)) }
    }

    var engineHasKeyboardFocus: Bool { surfaceState.isFocused }

    /// Through the view state, which is the only thing that knows where the
    /// surface ended up inside the hosted SwiftUI view.
    func engineTakeFocus() { surfaceState.requestFocus() }
}

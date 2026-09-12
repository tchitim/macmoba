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
                // An image counts: it is pasteable here even though it is not
                // text, and validating on text alone would grey out ⌘V for
                // exactly the screenshot case this pane needs most.
                let has = NSPasteboard.general.canReadObject(
                    forClasses: [NSString.self], options: nil)
                    || TerminalClipboard.clipboardImagePNG() != nil
                PasteTrace.log("validate paste: -> \(has ? "enabled" : "clipboard empty")")
                return has
            case Selector(("copy:")):
                // Always enabled, rather than asking `state.surface` — that is
                // a WEAK reference, and when it is nil this returned false and
                // left Copy permanently greyed out. Copy with no selection is
                // a harmless no-op; a Copy that can never be pressed is not.
                return true
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

        /// Catch ⌘V on the view, without going through the menu at all.
        ///
        /// The trace settled this: AppKit asked whether Paste applied, was
        /// told yes, and then never called `paste(_:)` here. The menu's action
        /// goes somewhere else, so everything downstream of it was unreachable
        /// no matter how the clipboard was read — which is why three attempts
        /// at reading the clipboard differently all changed nothing.
        ///
        /// A key equivalent on the view does not depend on which responder the
        /// menu hands its action to. Only plain ⌘V: ⇧⌘V is Paste as One Line
        /// and stays with the app's own menu item.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
                // On the view for the same reason as ⌘V below: the menu's
                // action does not arrive here. `copySelectedTextToPasteboard`
                // belongs to the view, which is certainly alive — this method
                // is running on it — rather than to the weak surface reference
                // that was making Copy look unavailable.
                let copied = copySelectedTextToPasteboard()
                PasteTrace.log("⌘C -> \(copied ? "copied" : "nothing selected")")
                // Nothing selected falls through, so ⌘C keeps whatever meaning
                // it would otherwise have had.
                if copied { return true }
                return super.performKeyEquivalent(with: event)
            }

            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
                PasteTrace.log("⌘V caught by performKeyEquivalent")
                PasteTrace.log(TerminalClipboard.describePasteboard())

                // A picture goes to the remote as a file, which is this app's
                // job and nothing the terminal could do.
                if let tab = menuTarget?.owningTab,
                   tab.config.sessionKind.authenticatesOverSSH,
                   let image = TerminalClipboard.clipboardImage() {
                    PasteTrace.log("⌘V: \(image.data.count) byte .\(image.fileExtension) -> upload")
                    tab.pasteImageToRemote(image.data, fileExtension: image.fileExtension)
                    return true
                }

                // Multi-line text is confirmed first, the same as on a
                // SwiftTerm pane. The guard exists so a clipboard holding
                // several commands cannot run them by being pasted, and it
                // should not depend on which library is drawing.
                let text = TerminalClipboard.clipboardText() ?? ""
                TerminalClipboard.confirmIfNeeded(text, window: window) { [weak self] choice in
                    guard let self else { return }
                    switch choice {
                    case .paste:
                        // libghostty's own paste, not this app's send-text
                        // call: routing it the other way is what broke plain
                        // text once already, and the binding applies the
                        // bracketed-paste framing a shell expects.
                        let sent = self.performBindingAction("paste_from_clipboard")
                        PasteTrace.log("⌘V: text via paste_from_clipboard -> "
                                       + "\(sent ? "sent" : "REFUSED")")
                    case .oneLine:
                        // Sent as input rather than through the clipboard,
                        // because the clipboard still holds the original. Safe
                        // to send raw: the newlines are exactly what has been
                        // taken out, so there is nothing for bracketed paste
                        // to protect against.
                        let line = PasteGuard.singleLine(text)
                        self.menuTarget?.sendAsInput(line)
                        PasteTrace.log("⌘V: \(line.count) chars as one line")
                    case .cancel:
                        PasteTrace.log("⌘V: cancelled at the confirmation")
                    }
                }
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    private var menuTarget: ClipboardMenuTarget?
    /// The view built for this pane.
    ///
    /// Selection used to be read through `surfaceState.surface`, which is a
    /// weak reference; when it was nil, Copy reported no selection and the
    /// menu item disabled itself. The view outlives the question.
    private weak var platformView: MenuTerminalView?

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
            self.platformView = view
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

    weak var engineOwner: TerminalTab?

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

    /// Reading the selection copies it, because the view offers no way to
    /// read without copying — and going through the weak surface reference is
    /// what made Copy unavailable in the first place. The pasteboard is where
    /// a copy was headed anyway.
    func engineSelection() -> String? {
        guard let view = platformView, view.copySelectedTextToPasteboard() else { return nil }
        return NSPasteboard.general.string(forType: .string)
    }

    /// True unless we can prove otherwise. The surface reference this used to
    /// ask is weak, and a nil there disabled Copy outright; an enabled Copy
    /// with nothing selected merely does nothing.
    var engineHasSelection: Bool { platformView != nil }

    /// The package does have select-all; what it did not have was a reference
    /// that survives. `AppTerminalView.selectAll` reaches the surface through
    /// the coordinator, which OWNS it — unlike `TerminalViewState.surface`,
    /// the weak mirror that went nil and disabled Copy.
    var engineCanSelectAll: Bool { platformView != nil }

    func engineSelectAll() { platformView?.selectAll(nil) }

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

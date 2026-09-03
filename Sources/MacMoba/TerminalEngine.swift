// The seam between this app and whichever library draws its terminals.
//
// STEP ONE OF TWO, AND DELIBERATELY ZERO BEHAVIOUR CHANGE. This introduces the
// protocol and makes SwiftTerm conform; nothing else moves. The same two-step
// shape the pane tree used when `PaneContent` was introduced, and for the same
// stated reason: a refactor mixed with a behaviour change leaves you unable to
// tell which one broke things.
//
// The surface turned out small. Everything the app asks a terminal view to do
// is below — thirteen operations, not a web of them — which is what makes
// swapping the engine a contained job rather than a rewrite.
//
// Not here on purpose, because neither has a libghostty equivalent yet and
// pretending otherwise would put a lie in the protocol:
//
//   - SEARCH (⌘F) reads the buffer row by row through SwiftTerm's own types.
//     libghostty gained `ghostty_search_*` upstream on 2026-08-31 but the Swift
//     package does not expose it, so wrapping that is its own step.
//   - THEMES set SwiftTerm's colour arrays directly. libghostty takes colours
//     through its controller config instead, which is a different shape rather
//     than a missing call.
//
//   - THE CLIPBOARD MENU is handed a raw view by the AppKit responder chain,
//     so it reads selection and bracketed-paste state off the concrete type.
//     Routing that means giving the responder chain something engine-agnostic
//     to find, which is a change to how the menu is reached rather than to
//     what it does.
//
// All three keep talking to the concrete type until then. That is visible in
// the code rather than hidden behind a protocol only one engine can satisfy.

import AppKit
import Foundation
import MacMobaCore
import SwiftTerm

/// This app's colour scheme type, spelled unambiguously.
///
/// `TerminalTheme` exists in both this app and GhosttyTerminal, and the engine
/// that has to convert between them imports both.
typealias AppTerminalTheme = TerminalTheme

/// What this app needs from a terminal, independent of who draws it.
///
/// Only operations with a real caller are here. An earlier draft also had a
/// `send` for injecting typed bytes, on the assumption that broadcast and
/// macros went through the view; they write straight to the connection, so it
/// had no callers in that byte-slice shape and was removed. It came back as
/// `engineSendText`, because macros fired at a LOCAL shell do go through the
/// view — the removal was one grep short. Bracketed
/// paste went the same way: only the clipboard menu asks, it asks the concrete
/// view, and libghostty frames pastes itself so the question does not arise
/// there.
@MainActor
protocol TerminalEngineView: AnyObject {
    /// The AppKit view, for the pane container to place and re-parent.
    var engineView: NSView { get }

    /// Which library is drawing this pane, for `macmoba list-tabs`.
    ///
    /// Added because there was no way to answer "am I on libghostty?" from
    /// outside — the question that prompted it came from the person who had
    /// just installed the build. A setting whose effect is invisible is a
    /// setting nobody can trust.
    var engineName: String { get }

    /// Bytes arriving from the far end.
    func engineFeed(_ bytes: ArraySlice<UInt8>)

    /// Type text into the terminal as though the user had, so it travels the
    /// same path a keystroke does. A macro fired at a local shell needs this:
    /// there is no connection to write to, and the PTY is reached through the
    /// terminal's own input handling.
    func engineSendText(_ text: String)

    /// The grid, which the transport must be told about so the remote wraps in
    /// the right place.
    var engineGrid: (cols: Int, rows: Int) { get }

    /// How many lines of history to keep.
    func engineSetScrollback(_ lines: Int)

    func engineSetFontSize(_ size: Double)

    /// Restyle without touching the scrollback.
    func engineApplyTheme(_ theme: AppTerminalTheme)

    /// Selected text, or nil when there is no selection.
    func engineSelection() -> String?
    var engineHasSelection: Bool { get }
    func engineSelectAll()
    /// False where the engine has no select-all, so the menu can leave the
    /// item out instead of offering one that does nothing.
    var engineCanSelectAll: Bool { get }

    /// Paste text as a paste rather than as typed keys, so a newline in it
    /// lands in the shell's edit line instead of running.
    func enginePaste(_ text: String)

    /// Bring a row into view — where a search result lands.
    func engineScroll(toRow row: Int)

    /// Scrollback plus screen, one entry per line, each with the row number
    /// `engineScroll(toRow:)` accepts.
    ///
    /// Rows rather than plain text because search has to scroll to what it
    /// finds, and the two engines number rows differently: SwiftTerm counts
    /// scroll-invariant rows that can start negative, libghostty counts from
    /// zero at the top of the scrollback. Returning the number alongside the
    /// text is what lets one search work against both.
    func engineTextLines() -> [(row: Int, text: String)]

    /// True when this view holds the keyboard, which decides whether a pane
    /// counts as focused.
    var engineHasKeyboardFocus: Bool { get }

    /// Give this terminal the keyboard.
    ///
    /// Cannot be `window.makeFirstResponder(engineView)` at the call site: the
    /// libghostty engine hands out a hosting view, and making THAT the first
    /// responder focuses the host rather than the surface inside it — the
    /// terminal draws, and nothing typed arrives.
    func engineTakeFocus()

    // What the terminal tells the app. Closures rather than a delegate
    // protocol, because a delegate would have to be spelled in one engine's
    // types — `TerminalViewDelegate` names SwiftTerm's TerminalView in every
    // method — and that is exactly the coupling this seam exists to remove.

    /// The user typed, pasted, or the terminal answered a device query. These
    /// bytes go to the far end.
    var engineOnInput: ((ArraySlice<UInt8>) -> Void)? { get set }
    /// The grid changed, so the far end has to be told.
    var engineOnResize: ((Int, Int) -> Void)? { get set }
    var engineOnTitle: ((String) -> Void)? { get set }
    var engineOnBell: (() -> Void)? { get set }
    /// A clicked hyperlink (OSC 8).
    var engineOnOpenLink: ((String) -> Void)? { get set }
    /// The remote asked to put something on the clipboard (OSC 52).
    var engineOnClipboardCopy: ((Data) -> Void)? { get set }
}

extension TerminalEngineView {
    /// The same content as one string, for `read-screen` and for the session
    /// log's "what was on screen before logging started" header. Derived so
    /// there is one traversal to be right rather than two to keep in step.
    func engineDumpText() -> String {
        var lines = engineTextLines().map(\.text)
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - SwiftTerm

/// Wraps SwiftTerm behind the seam.
///
/// A wrapper rather than a conformance on `TerminalView` itself, because the
/// callbacks above are stored properties and an extension cannot add those.
/// It also puts SwiftTerm's delegate in one place instead of making every tab
/// implement a protocol written in SwiftTerm's own types.
@MainActor
final class SwiftTermEngine: NSObject, TerminalEngineView {
    let view: TerminalView

    var engineOnInput: ((ArraySlice<UInt8>) -> Void)?
    var engineOnResize: ((Int, Int) -> Void)?
    var engineOnTitle: ((String) -> Void)?
    var engineOnBell: (() -> Void)?
    var engineOnOpenLink: ((String) -> Void)?
    var engineOnClipboardCopy: ((Data) -> Void)?

    /// The pane this draws for.
    ///
    /// Exists because the clipboard reaches a terminal through the AppKit
    /// responder chain, holds only the view, and used to recover the tab with
    /// `terminalDelegate as? TerminalTab`. Once this wrapper became the
    /// delegate that cast returned nil for every pane, and pasting a
    /// screenshot into an SSH session silently stopped uploading — it fell
    /// through to the text path and did nothing visible. No test noticed,
    /// because what broke was a cast, not a behaviour anything asserts on.
    weak var owner: TerminalTab?

    /// Callers that still need SwiftTerm specifically — search reads its buffer
    /// types, themes set its colour arrays. Both are named in this file's
    /// header as the two things not yet behind the seam.
    var swiftTermView: TerminalView { view }

    /// - Parameter installDelegate: whether this wrapper should become the
    ///   view's `terminalDelegate`.
    ///
    ///   False for a `LocalProcessTerminalView`, which **is its own delegate** —
    ///   `MacLocalTerminalView.swift:85` sets `terminalDelegate = self`, and
    ///   that is the path its keystrokes take to the PTY. Taking it over
    ///   disconnects the shell silently: the terminal still draws, the tests
    ///   still pass, and nothing you type arrives. Which is exactly what
    ///   happened the first time this wrapper went in.
    init(view: TerminalView, installDelegate: Bool = true) {
        self.view = view
        super.init()
        if installDelegate { view.terminalDelegate = self }
    }

    var engineView: NSView { view }

    var engineName: String { "swiftterm" }

    func engineFeed(_ bytes: ArraySlice<UInt8>) { view.feed(byteArray: bytes) }

    func engineSendText(_ text: String) { view.send(txt: text) }

    var engineGrid: (cols: Int, rows: Int) {
        let terminal = view.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    func engineSetScrollback(_ lines: Int) { view.getTerminal().changeScrollback(lines) }

    func engineSetFontSize(_ size: Double) {
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func engineApplyTheme(_ theme: AppTerminalTheme) { theme.apply(to: view) }

    func engineSelection() -> String? { view.getSelection() }

    var engineHasSelection: Bool { view.selectionActive }

    var engineCanSelectAll: Bool { true }

    /// Bracketed paste is honoured here, because SwiftTerm leaves that to the
    /// caller. libghostty frames pastes itself, which is why its version of
    /// this is a single call.
    func enginePaste(_ text: String) {
        guard !text.isEmpty else { return }
        let bracketed = view.getTerminal().bracketedPasteMode
        if bracketed { view.send(data: EscapeSequences.bracketedPasteStart[0...]) }
        view.send(txt: text)
        if bracketed { view.send(data: EscapeSequences.bracketedPasteEnd[0...]) }
    }

    func engineSelectAll() { view.selectAll(nil) }

    func engineScroll(toRow row: Int) { view.scrollTo(row: row) }

    func engineTextLines() -> [(row: Int, text: String)] {
        let terminal = view.getTerminal()
        let (_, rows) = terminal.getDims()
        // Scroll-invariant rows count from the very top of the scrollback, so
        // start at the earliest one rather than at the viewport.
        let top = terminal.getTopVisibleRow()
        var out: [(row: Int, text: String)] = []
        for row in min(0, top)..<(top + rows) {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            out.append((row, line.translateToString(trimRight: true)))
        }
        return out
    }

    var engineHasKeyboardFocus: Bool {
        view.window?.isKeyWindow == true && view.window?.firstResponder === view
    }

    func engineTakeFocus() { view.window?.makeFirstResponder(view) }
}

// MARK: - SwiftTerm's delegate, translated into the seam's callbacks
//
// Everything SwiftTerm reports arrives here in its own vocabulary and leaves
// as a plain closure call, so the rest of the app never names a SwiftTerm type
// to find out that the user typed something.
extension SwiftTermEngine: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        engineOnInput?(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        engineOnResize?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        engineOnTitle?(title)
    }

    func bell(source: TerminalView) {
        engineOnBell?()
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        engineOnOpenLink?(link)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        engineOnClipboardCopy?(content)
    }

    // Not routed through the seam because nothing in this app acted on them
    // even when SwiftTerm offered them. Adding closures nobody calls would
    // make the protocol look richer than the behaviour behind it.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

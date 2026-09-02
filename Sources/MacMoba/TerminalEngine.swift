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
// Both keep talking to the concrete type until then. That is visible in the
// code rather than hidden behind a protocol that only one engine can satisfy.

import AppKit
import Foundation
import MacMobaCore
import SwiftTerm

/// What this app needs from a terminal, independent of who draws it.
@MainActor
protocol TerminalEngineView: AnyObject {
    /// The AppKit view, for the pane container to place and re-parent.
    var engineView: NSView { get }

    /// Bytes arriving from the far end.
    func engineFeed(_ bytes: ArraySlice<UInt8>)

    /// Bytes going to the far end, entered by the user.
    func engineSend(_ bytes: ArraySlice<UInt8>)

    /// The grid, which the transport must be told about so the remote wraps in
    /// the right place.
    var engineGrid: (cols: Int, rows: Int) { get }

    /// How many lines of history to keep.
    func engineSetScrollback(_ lines: Int)

    /// Whether the program running inside asked for bracketed paste, which
    /// decides whether a multi-line paste is framed or typed.
    var engineBracketedPaste: Bool { get }

    func engineSetFontSize(_ size: Double)

    /// Selected text, or nil when there is no selection.
    func engineSelection() -> String?
    func engineSelectAll()

    /// Bring a row into view — where a search result lands.
    func engineScroll(toRow row: Int)

    /// Scrollback plus screen as plain text, for `read-screen` and for the
    /// session log's "what was on screen before logging started" header.
    func engineDumpText() -> String

    /// True when this view holds the keyboard, which decides whether a pane
    /// counts as focused.
    var engineHasKeyboardFocus: Bool { get }
}

// MARK: - SwiftTerm

extension TerminalView: TerminalEngineView {
    var engineView: NSView { self }

    func engineFeed(_ bytes: ArraySlice<UInt8>) { feed(byteArray: bytes) }

    func engineSend(_ bytes: ArraySlice<UInt8>) { send(data: bytes) }

    var engineGrid: (cols: Int, rows: Int) {
        let terminal = getTerminal()
        return (terminal.cols, terminal.rows)
    }

    func engineSetScrollback(_ lines: Int) { getTerminal().changeScrollback(lines) }

    var engineBracketedPaste: Bool { getTerminal().bracketedPasteMode }

    func engineSetFontSize(_ size: Double) {
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func engineSelection() -> String? { getSelection() }

    func engineSelectAll() { selectAll(nil) }

    func engineScroll(toRow row: Int) { scrollTo(row: row) }

    func engineDumpText() -> String {
        let terminal = getTerminal()
        let (_, rows) = terminal.getDims()
        let top = terminal.getTopVisibleRow()
        var lines: [String] = []
        for row in min(0, top)..<(top + rows) {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    var engineHasKeyboardFocus: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }
}

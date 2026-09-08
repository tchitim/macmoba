// One place to build the libghostty controller for both experimental panes,
// so a comparison against SwiftTerm is against the same settings rather than
// against two sets of defaults that happen not to match.

import Foundation
import GhosttyTerminal
import MacMobaCore

@MainActor
enum GhosttyControllerConfig {
    /// Approximate bytes libghostty needs per scrollback line.
    ///
    /// The two engines count scrollback in different units — SwiftTerm in
    /// LINES, libghostty in BYTES of storage — so exact equivalence is not
    /// available and this is an estimate: a wide-ish row of cells plus row
    /// overhead. It lands close: at 124 columns, 10,000 lines works out near
    /// 10MB, which is what Ghostty's own default happens to be. So this
    /// changes little today; what it buys is that the two panes now track the
    /// SAME user setting instead of agreeing by coincidence, and stop agreeing
    /// the moment that setting is changed.
    private static let bytesPerLine = 1024

    /// A view state whose controller carries the shared settings.
    static func makeState() -> TerminalViewState {
        TerminalViewState(controller: make())
    }

    static func make() -> TerminalController {
        let lines = TerminalDefaults.scrollback()
        let limit = lines * bytesPerLine
        return TerminalController { builder in
            builder.withBackgroundOpacity(1)
            builder.withCustom("scrollback-limit", String(limit))
            // The host owns every shortcut.
            //
            // Ghostty ships keybinds for a standalone terminal — super+t for a
            // new tab, super+d to split, super+k to clear, super+w, the font
            // sizes — and this app's menus use the same combinations for its
            // own versions of those things. libghostty won, swallowing the key
            // and performing an action no host implements, so ⌘T did nothing
            // at all. ⌘D, ⌘K and ⌘W were queued up behind it.
            //
            // Clearing them is the whole class of bug rather than the one
            // reported. Nothing is lost that this app does not already
            // provide: copy and paste arrive through the Edit menu and the
            // responder chain, and the menu actions call libghostty by name
            // rather than through a keybind.
            builder.withCustom("keybind", "clear")
        }
    }
}

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
        }
    }
}

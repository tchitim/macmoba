// How much history a terminal keeps.
//
// SwiftTerm defaults to 500 lines, which is a terminal-widget default rather
// than a session-manager one: 500 lines is a few seconds of a build log, and
// the first thing anyone does with a long-running session is scroll back
// further than that. The buffer grows as output arrives rather than being
// allocated up front, so a raised ceiling costs nothing on an idle pane.

import Foundation

public enum TerminalDefaults {
    public static let scrollbackKey = "terminalScrollback"
    public static let defaultScrollback = 10_000

    /// Keep it within what a person could plausibly want and a Mac can hold:
    /// one pane at 200,000 lines is hundreds of megabytes, and a fleet of them
    /// is how an app gets killed for memory.
    public static func clampedScrollback(_ lines: Int) -> Int {
        min(max(lines, 500), 100_000)
    }

    /// The setting, or the default when nothing has been chosen.
    public static func scrollback(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: scrollbackKey)
        return stored == 0 ? defaultScrollback : clampedScrollback(stored)
    }
}

// Which renderer draws the terminal.
//
// SwiftTerm's CoreGraphics path repaints the *whole* view whenever the
// selection changes, and a selection changes on every mouse-move of a drag.
// Measured on this Mac that repaint costs 7.2 ms at 1200x800 and 22.4 ms at
// 2560x1440 — the second one blows the 16.7 ms frame budget, which is exactly
// the stutter people report when dragging a selection across a big window.
// SwiftTerm's Metal path marks only the dirty rows instead.
//
// It stays opt-in because it is a renderer swap: it allocates an MTKView,
// rebinds on every window change, and falls back to CoreGraphics if the GPU
// pipeline fails to build. Off by default means a bug here can never break a
// terminal for someone who never asked for it.
public extension TerminalDefaults {
    static let metalRendererKey = "terminalMetalRenderer"

    static func usesMetalRenderer(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: metalRendererKey) as? Bool ?? false
    }
}

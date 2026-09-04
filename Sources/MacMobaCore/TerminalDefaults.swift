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
// ON by default since the renderer was actually measured. It was opt-in while
// the only argument for it was the reasoning above; `terminal-render-bench`
// now puts a terminal in a real window, disables vsync and counts frames that
// really drew:
//
//     1200x800    CoreGraphics 4.0 ms (250 fps)    Metal 0.70 ms (1450 fps)
//     2560x1440   CoreGraphics 8.5 ms (117 fps)    Metal 0.97 ms (1035 fps)
//
// Against the 16.7 ms frame budget that is the difference between fitting and
// not: at 1440p CoreGraphics spends 8.5 ms on ONE pane, so four panes overrun
// at 34 ms, while Metal's four cost 3.9 ms. A large window, split, is this
// app's ordinary case rather than an edge one.
//
// The caution that kept it off is still respected rather than discarded.
// `setUseMetal` throws instead of trapping when the device or pipeline cannot
// be built, SwiftTerm falls back to CoreGraphics on a later rebind failure,
// and `TerminalRendering.apply` logs rather than propagates — so the failure
// mode is a terminal that draws the old way, not one that does not draw.
// Metal starting inside a packaged .app was verified too
// (scripts/check-metal-in-app.sh), because a shader bundle that resolves only
// on the build machine is exactly how the libghostty spike broke.
//
// Anyone who explicitly turned it off keeps it off: this reads the stored
// value first and only falls back to the default when none was ever set.
public extension TerminalDefaults {
    static let metalRendererKey = "terminalMetalRenderer"

    static func usesMetalRenderer(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: metalRendererKey) as? Bool ?? true
    }
}

// Which library draws the terminals.
//
// Off by default while the libghostty path is still catching up: it has no
// ⌘F, no themes, no select-all, and its screen dump is the viewport rather
// than the whole scrollback. Each of those is named at its own call site.
// It is measurably the faster engine — 0.149s against SwiftTerm's 0.346s for
// 14MB of CJK into a local shell, which is engine and not renderer, since
// SwiftTerm was on its quicker CoreGraphics path for that number — so this is
// a migration in progress rather than an experiment kept at arm's length.
public extension TerminalDefaults {
    static let engineKey = "terminalEngine"

    /// Info.plist key a build may carry to change the default. Written by
    /// `make-app.sh` only when GHOSTTY_DEFAULT=1, so a published release cannot
    /// pick it up by accident.
    static let engineBundleKey = "MacMobaDefaultEngine"

    /// A setting the user made wins. Failing that, what this build was made to
    /// default to. Failing that, SwiftTerm.
    ///
    /// The build-level default exists so local test builds can run libghostty
    /// while the releases stay on SwiftTerm, without the two differing in
    /// source — a branch that has to be remembered to change back is a branch
    /// that eventually is not.
    static func usesGhosttyEngine(from defaults: UserDefaults = .standard,
                                  bundle: Bundle = .main) -> Bool {
        if let chosen = defaults.object(forKey: engineKey) as? Bool { return chosen }
        let declared = bundle.object(forInfoDictionaryKey: engineBundleKey) as? String
        return declared?.lowercased() == "ghostty"
    }
}

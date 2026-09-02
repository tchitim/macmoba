// Turning SwiftTerm's GPU renderer on and off.
//
// `setUseMetal` throws when the Metal device or pipeline cannot be built, and
// SwiftTerm itself falls back to CoreGraphics if a later window rebind fails.
// Either way the terminal keeps working, so a failure here is worth reporting
// but never worth propagating: nobody should lose a session because a
// rendering preference did not take.

import Foundation
import SwiftTerm
import MacMobaCore
import os

private let renderLog = Logger(subsystem: "com.macmoba.app", category: "rendering")

@MainActor
enum TerminalRendering {
    /// Apply the current preference to a view. Safe to call repeatedly —
    /// SwiftTerm returns early when the renderer is already in the asked-for
    /// state.
    static func apply(to view: TerminalView, enabled: Bool = TerminalDefaults.usesMetalRenderer()) {
        do {
            try view.setUseMetal(enabled)
            // Says which renderer a pane ended up on. Worth a line in the log:
            // Metal silently falling back to CoreGraphics looks identical from
            // the outside, and "is the GPU actually being used" was otherwise
            // unanswerable without attaching a debugger — which is a poor
            // position to be in for the setting that is now the default.
            // .notice, not .info: info-level messages live in memory and never
            // reach `log show`, which makes them useless for the question this
            // line exists to answer after the fact.
            renderLog.notice("terminal renderer: \(enabled ? "Metal" : "CoreGraphics", privacy: .public)")
        } catch {
            renderLog.error("Metal renderer unavailable, staying on CoreGraphics: \(String(describing: error))")
        }
    }
}

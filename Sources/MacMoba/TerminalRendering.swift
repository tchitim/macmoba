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
        } catch {
            renderLog.error("Metal renderer unavailable, staying on CoreGraphics: \(String(describing: error))")
        }
    }
}

// Reopening the sessions you had open, and reconnecting them after the Mac
// wakes. The app-lifecycle wiring lives in the app target; the two decisions
// that are easy to get subtly wrong live here where a test can hold them still.

import Foundation

public enum WorkspaceRestore {
    /// The session ids to reopen on launch: the saved list, in its saved order,
    /// keeping only ids that still exist and dropping duplicates. A session
    /// deleted since last launch simply does not come back rather than erroring.
    public static func restorableIDs(saved: [String], available: [String]) -> [String] {
        let present = Set(available)
        var seen = Set<String>()
        var result: [String] = []
        for id in saved where present.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }
}

public enum WakeReconnectPolicy {
    /// Whether a pane should reconnect after the Mac wakes.
    ///
    /// The rule is deliberately conservative: only bring back what was actually
    /// connected when we went to sleep, and never fight the user — if they
    /// closed or disconnected the pane while the machine was asleep (or between
    /// sleep and wake), leave it closed.
    public static func shouldReconnect(wasConnectedAtSleep: Bool,
                                       closedByUserSinceSleep: Bool) -> Bool {
        wasConnectedAtSleep && !closedByUserSinceSleep
    }
}

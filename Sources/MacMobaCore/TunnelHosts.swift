// Which sessions can carry a port forward.
//
// A tunnel is an SSH channel, so the session that hosts one has to speak SSH.
// A remote desktop, a serial line or a web page cannot carry a forward however
// reachable the machine behind it is — offering them in the picker only invites
// a tunnel that can never start.

import Foundation

public enum TunnelHosts {
    /// The sessions a tunnel may be attached to. Mosh counts: its config is an
    /// SSH login (that is how mosh bootstraps), so the forward opens over the
    /// same credentials and jump chain.
    public static func eligible(in sessions: [SessionConfig]) -> [SessionConfig] {
        sessions.filter { $0.sessionKind.authenticatesOverSSH }
    }

    /// Whether a saved tunnel still points at something that can carry it —
    /// false for one made before the picker was filtered, or whose session was
    /// deleted or changed protocol since.
    public static func isEligible(sessionID: String, in sessions: [SessionConfig]) -> Bool {
        eligible(in: sessions).contains { $0.id == sessionID }
    }
}

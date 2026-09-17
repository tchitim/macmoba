// Launch a shell inside tmux, and name the session so it can be found again.
//
// KKTerm's ARCHITECTURE.md draws the line this borrows: tmux is transport
// recovery, not a second Mosh. When enabled on a connection, the shell is
// launched with `tmux new-session -A -s <name>`; if the SSH channel dies
// unexpectedly, one bounded reattach to the same name gets the session back.
// Mosh survives losing the network; tmux survives losing the client.
//
// Two hazards this file exists to handle:
//
//  1. tmux may not be installed on the far side. The launch must fall back to
//     a plain login shell rather than killing the whole channel — a session
//     that will not open at all is far worse than one without tmux. So the
//     command probes first and `exec`s one or the other.
//
//  2. The session name must be STABLE across reconnects, or a reattach opens
//     a second empty session beside the first. It is derived from durable
//     identity (the saved session id and the pane's position), never from a
//     UUID minted per launch.

import Foundation

public enum TmuxLaunch {
    /// A tmux-safe session name: `mm-<slug>-<pane>`.
    ///
    /// tmux forbids `.` and `:` in a session name (they address windows and
    /// panes) and treats a name as a prefix on lookup, so two names where one
    /// is a prefix of the other would collide on reattach. Everything outside
    /// `[A-Za-z0-9_-]` folds to `_`, and the pane index on the end keeps two
    /// panes of the same saved session apart.
    public static func sessionName(sessionID: String, paneIndex: Int) -> String {
        // Cap the slug so the whole name stays well under any sane limit and
        // stays readable in `tmux ls`.
        let capped = String(fold(sessionID).prefix(48))
        return "mm-\(capped)-\(paneIndex)"
    }

    /// Fold to the characters a tmux session name may safely hold. tmux reads
    /// `.` and `:` as window/pane addresses and matches a name as a prefix, so
    /// anything outside `[A-Za-z0-9_-]` becomes `_`.
    static func fold(_ raw: String) -> String {
        String(raw.map { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        })
    }

    /// The name a launch will attach to: the user's chosen name if they gave
    /// one, otherwise the stable generated one. A chosen name is folded but
    /// NOT prefixed with `mm-` — it is the user's, meant to match a session
    /// they may have made by hand (`tmux new -s work`), so `work` stays
    /// `work`. Blank or all-unsafe input falls back to the generated name.
    public static func resolvedName(explicit: String?, sessionID: String,
                                    paneIndex: Int) -> String {
        if let explicit {
            let folded = fold(explicit.trimmingCharacters(in: .whitespaces))
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            if !folded.isEmpty { return String(folded.prefix(64)) }
        }
        return sessionName(sessionID: sessionID, paneIndex: paneIndex)
    }

    /// The command to run instead of a bare shell, or nil to keep the plain
    /// shell request. `enabled` false returns nil so the caller has one branch.
    ///
    /// `command -v tmux` is the portable "is it installed" test — a builtin in
    /// every POSIX shell, unlike `which`. On success `exec tmux` replaces the
    /// probing shell so no extra process lingers; on failure `exec` the login
    /// shell, so a remote without tmux still gets exactly what it got before
    /// this feature existed. `$SHELL` is preferred, `sh -l` the floor.
    ///
    /// The probe MUST run under a login shell. sshd delivers this through an
    /// exec channel, i.e. a NON-login shell whose PATH is the bare system
    /// default (`/usr/bin:/bin:/usr/sbin:/sbin`). A tmux installed by Homebrew
    /// (`/opt/homebrew/bin`, `/usr/local/bin`) is then not on PATH, so
    /// `command -v tmux` reports it missing and the session silently falls back
    /// to a plain shell — tmux looks broken though it is installed. So re-exec
    /// through `$SHELL -lc` first: the user's profile sets PATH before the
    /// probe runs, and only then is "is tmux installed" an honest question.
    public static func launchCommand(enabled: Bool,
                                     sessionID: String,
                                     paneIndex: Int,
                                     explicitName: String? = nil) -> String? {
        guard enabled else { return nil }
        let name = resolvedName(explicit: explicitName, sessionID: sessionID,
                                paneIndex: paneIndex)
        // Double-quoted for the login shell; the name has no quotes, `$` or
        // backtick to escape (sessionName/resolvedName guarantee it), so it is
        // also safe to sit inside the single-quoted `-lc` body below.
        let inner = "command -v tmux >/dev/null 2>&1 && "
            + "exec tmux new-session -A -s \"\(name)\" || "
            + "exec \"${SHELL:-/bin/sh}\" -l"
        // Single-quoted body for the outer (non-login) remote shell, so it
        // reaches the login shell verbatim; the login shell then expands the
        // `${SHELL}` and probes tmux with the profile's PATH in place.
        return "exec \"${SHELL:-/bin/sh}\" -lc '\(inner)'"
    }
}

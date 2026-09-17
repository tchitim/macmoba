// Build a `tail -f` command for the SFTP browser's "Follow" action.
//
// An infrastructure user does this by hand daily: open a shell to the host
// the file browser is already connected to, and tail a log. Follow makes it
// one menu item — a new terminal pane on the same session, launched straight
// into the tail.
//
// The whole reason this is its own function is the path. A remote path is
// arbitrary text arriving from a directory listing; it can hold spaces,
// quotes, `$`, a leading `-`. It goes into a shell command, so it must be
// quoted exactly once and exactly right, and that is worth a test rather than
// a hopeful bit of string interpolation at the call site.

import Foundation

public enum FollowCommand {
    /// `tail -n <lines> -f -- '<path>'`, safe for any path.
    ///
    /// Single quotes disable every shell metacharacter, and the one thing a
    /// single-quoted string cannot contain — a single quote — is spliced the
    /// standard way: close, an escaped quote, reopen. `--` stops a path that
    /// begins with `-` from being read as options. `-F` would follow across
    /// rotation, but not every `tail` has it (BusyBox); `-f` is universal, and
    /// a rotated log is a rarer case than a missing flag.
    public static func command(path: String, lines: Int = 100) -> String {
        "tail -n \(lines) -f -- \(singleQuoted(path))"
    }

    /// Wrap in single quotes, escaping any single quote within.
    static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// Replacement tokens — %host%, %username% and friends — swapped for a session's
// own values.
//
// The point is templates: a template's on-connect script is written once as
// `ssh-copy-id %username%@%host%`, and every session made from it runs the line
// with its own host and user filled in. Tokens also keep a hand-written script
// correct when a host is later renamed, since nothing is hard-coded.
//
// Matching is case-insensitive (%HOST% works too) and unknown tokens are left
// untouched — a stray "%" in a command is not something to mangle.

import Foundation

public enum TokenExpander {
    /// The tokens understood, mapped to a session's value.
    static func values(for session: SessionConfig) -> [String: String] {
        [
            "host": session.host,
            "port": String(session.port),
            "username": session.username,
            "user": session.username,
            "name": session.name,
            "group": session.group ?? "",
            "domain": session.domain ?? "",
            "weburl": session.webURL ?? "",
        ]
    }

    /// `text` with every known `%token%` replaced by `session`'s value. Nil in,
    /// nil out; unknown tokens are left exactly as written.
    public static func expand(_ text: String?, in session: SessionConfig) -> String? {
        text.map { expand($0, in: session) }
    }

    /// Non-optional overload for callers that always have a string.
    public static func expand(_ text: String, in session: SessionConfig) -> String {
        guard text.contains("%") else { return text }
        let values = self.values(for: session)
        var result = ""
        result.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "%",
                  let close = text[text.index(after: index)...].firstIndex(of: "%") else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let name = text[text.index(after: index)..<close].lowercased()
            if let value = values[name] {
                result.append(value)
                index = text.index(after: close)
            } else {
                // Not a token we know — keep the literal "%" and carry on, so
                // the next "%" still has a chance to open a real token.
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }
}

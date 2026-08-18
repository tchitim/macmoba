// Cloning a session.
//
// Everything is kept except the two things that must not be shared: the id
// (two sessions with one id are the same session as far as the vault, tabs and
// jump-host references are concerned) and the name (a list with two identical
// rows is unusable).

import Foundation

public enum SessionDuplicate {
    /// A copy of `config` with a fresh id and a name that is not taken.
    ///
    /// Everything else comes along — username, port, password, key, group,
    /// jump host, and the per-protocol settings — because the point of
    /// duplicating is to change one or two fields, not to fill it all in again.
    public static func copy(of config: SessionConfig,
                            existingNames: [String]) -> SessionConfig {
        var copy = config
        copy.id = UUID().uuidString
        copy.name = uniqueName(basedOn: config.name, existing: Set(existingNames))
        return copy
    }

    /// "Server" → "Server copy" → "Server copy 2" → "Server copy 3".
    ///
    /// Duplicating a copy extends the number rather than stacking the word, so
    /// a few rounds do not produce "Server copy copy copy".
    public static func uniqueName(basedOn name: String, existing: Set<String>) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let base = stem(of: trimmed.isEmpty ? "Session" : trimmed)

        let first = "\(base) copy"
        if !existing.contains(first) { return first }
        // Start at 2: "copy" is the first, "copy 2" the second.
        var index = 2
        while existing.contains("\(base) copy \(index)") {
            index += 1
            // A guard against a pathological vault rather than a real limit.
            if index > 10_000 { return "\(base) copy \(UUID().uuidString.prefix(4))" }
        }
        return "\(base) copy \(index)"
    }

    /// Strips a trailing " copy" or " copy N" so the suffix is not repeated.
    static func stem(of name: String) -> String {
        var text = name
        // " copy 12" → " copy"
        if let range = text.range(of: #" copy \d+$"#, options: .regularExpression) {
            text.removeSubrange(range)
            return text
        }
        if text.hasSuffix(" copy") {
            text.removeLast(" copy".count)
            return text
        }
        return text
    }
}

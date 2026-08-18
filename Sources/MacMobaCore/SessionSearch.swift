// Filtering the sidebar when a saved-session list grows past what fits on a
// screen — the point of having tags and notes in the first place.
//
// The match is deliberately broad and case-insensitive: someone typing "prod"
// wants every host whose name, address, group, tag or note mentions it, without
// thinking about which field it lives in. An empty query matches everything, so
// the filter is invisible until used.

import Foundation

public enum SessionSearch {
    /// Whether `session` should show for `query`. Empty/whitespace query → true.
    public static func matches(_ session: SessionConfig, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }

        var haystacks = [
            session.name,
            session.host,
            session.username,
            session.group ?? "",
            session.notes ?? "",
            session.webURL ?? "",
        ]
        haystacks.append(contentsOf: session.tags ?? [])
        return haystacks.contains { $0.lowercased().contains(needle) }
    }

    /// Turn a comma-separated field into clean tags: trimmed, no empties, and
    /// de-duplicated case-insensitively (the first spelling wins, so "Prod"
    /// then "prod" keeps "Prod").
    public static func normalizedTags(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.split(separator: ",") {
            let tag = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                result.append(tag)
            }
        }
        return result
    }

    /// The tags of a session as a single editable string.
    public static func tagString(_ tags: [String]?) -> String {
        (tags ?? []).joined(separator: ", ")
    }
}

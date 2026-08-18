// Nested session groups, the Royal TSX folder tree — built on a naming
// convention rather than a schema change: a group named "Production/Linux" is the
// Linux folder inside Production. The vault keeps storing one string per session
// (old vaults stay readable, RDCMan imports already produce these paths); the
// tree exists at display time, derived here.
//
// Pure functions only, so every tree rule — implied parents, hierarchical
// order, collapse visibility, prefix-safe renames — is unit-testable.

import Foundation

public enum GroupTree {
    public static let separator: Character = "/"

    /// One row of the sidebar's folder listing.
    public struct Row: Equatable, Sendable {
        /// Full path ("Production/Linux") — the value stored on member sessions.
        public let path: String
        /// The last path component ("Linux") — what the row displays.
        public let name: String
        /// Nesting depth: 0 for a top-level folder.
        public let depth: Int
    }

    /// The folders to draw, in depth-first order, with parents implied: given
    /// sessions in "Production/Linux", the "Production" folder exists even though no
    /// session names it directly. `folders` adds paths that exist in their own
    /// right — an empty folder just made by "New Subfolder…" has no session to
    /// imply it. Folders inside a collapsed ancestor are omitted (the collapsed
    /// folder itself still shows).
    public static func displayRows(groups: [String],
                                   folders: [String] = [],
                                   collapsed: Set<String> = []) -> [Row] {
        // Expand every path to include its ancestors, deduplicated.
        var all = Set<String>()
        for group in (groups + folders) where !group.isEmpty {
            var components: [Substring] = []
            for part in group.split(separator: separator) {
                components.append(part)
                all.insert(components.joined(separator: String(separator)))
            }
        }
        // Depth-first order falls out of sorting by component sequence.
        let sorted = all.sorted {
            componentsOf($0).lexicographicallyPrecedes(componentsOf($1))
        }
        return sorted.compactMap { path in
            let parts = componentsOf(path)
            // Hidden while any strict ancestor is collapsed.
            for end in 1..<max(parts.count, 1) {
                let ancestor = parts[0..<end].joined(separator: String(separator))
                if collapsed.contains(ancestor) { return nil }
            }
            return Row(path: path, name: parts.last ?? path, depth: parts.count - 1)
        }
    }

    /// "Production/Linux/prod" → ["Production", "Production/Linux"], outermost first.
    public static func ancestors(of path: String) -> [String] {
        let parts = componentsOf(path)
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts[0..<$0].joined(separator: String(separator)) }
    }

    /// The path's parent, or nil at top level. Used to walk inheritance upward.
    public static func parent(of path: String) -> String? {
        ancestors(of: path).last
    }

    /// True when `path` lives inside `ancestor` (strictly — a path is not its
    /// own descendant).
    public static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        path.hasPrefix(ancestor + String(separator))
    }

    /// True when a session in `group` belongs under the folder at `path` —
    /// either directly or in a subfolder. Powers folder counts and dashboards.
    public static func contains(_ path: String, group: String?) -> Bool {
        guard let group, !group.isEmpty else { return false }
        return group == path || isDescendant(group, of: path)
    }

    /// A group string after renaming the folder `old` to `new`: exact matches
    /// move, descendants keep their tail ("old/x" → "new/x"), everything else
    /// is untouched. Renaming a parent must carry its subtree along.
    public static func rename(_ group: String, from old: String, to new: String) -> String {
        if group == old { return new }
        if isDescendant(group, of: old) {
            return new + String(group.dropFirst(old.count))
        }
        return group
    }

    /// The path of a new child folder called `name` under `parent` (nil parent
    /// = top level), or nil when the name is unusable. A name is one component:
    /// slashes in it would silently create extra nesting, so they are stripped.
    public static func childPath(of parent: String?, name: String) -> String? {
        let clean = name
            .replacingOccurrences(of: String(separator), with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard let parent, !parent.isEmpty else { return clean }
        return parent + String(separator) + clean
    }

    private static func componentsOf(_ path: String) -> [String] {
        path.split(separator: separator).map(String.init)
    }
}

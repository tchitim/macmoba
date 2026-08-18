// Type-select: start typing in the sidebar and the matching connection is
// selected, the way it works in Finder and every other Mac list.
//
// Two rules carry the whole feel of it, and both are easy to get wrong:
//
//   * Letters typed in quick succession build one prefix ("we" → web-server),
//     but a pause starts a fresh search. Without the timeout, a letter typed a
//     minute later would extend a stale prefix and match nothing.
//   * Tapping the SAME letter repeatedly cycles through everything starting
//     with it, rather than searching for "aaa". That is how people step
//     through a run of similarly-named hosts.
//
// Pure logic, so both rules are testable without a keyboard.

import Foundation

/// Accumulates keystrokes into a search prefix that expires after a pause.
public struct TypeSelectBuffer: Sendable {
    /// How long a keystroke keeps the prefix alive. Matches the Mac's own
    /// type-select feel; long enough to type a word, short enough that coming
    /// back later starts over.
    public static let defaultTimeout: TimeInterval = 1.0

    public let timeout: TimeInterval
    public private(set) var prefix = ""
    private var lastKeyAt: TimeInterval?

    public init(timeout: TimeInterval = TypeSelectBuffer.defaultTimeout) {
        self.timeout = timeout
    }

    /// Add a character and return the prefix to search for now.
    @discardableResult
    public mutating func append(_ character: Character, at now: TimeInterval) -> String {
        if let last = lastKeyAt, now - last >= timeout {
            prefix = ""
        }
        prefix.append(character)
        lastKeyAt = now
        return prefix
    }

    public mutating func reset() {
        prefix = ""
        lastKeyAt = nil
    }

    /// Whether a character is worth collecting: printable, not a control key,
    /// and not a space (space is "scroll"/"activate" on a list, not a search).
    public static func isSearchable(_ character: Character) -> Bool {
        guard !character.isWhitespace, !character.isNewline else { return false }
        return character.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

public enum TypeSelect {
    /// The index of the row to select for `prefix`.
    ///
    /// A single character steps to the NEXT match after `current` and wraps —
    /// that is what makes repeated taps cycle. A longer prefix always searches
    /// from the top, so refining what you typed never jumps somewhere odd.
    public static func match(prefix: String, in names: [String],
                             current: Int?) -> Int? {
        guard !prefix.isEmpty, !names.isEmpty else { return nil }
        let needle = prefix.lowercased()

        if prefix.count == 1 {
            let start = ((current ?? -1) + 1) % names.count
            for offset in 0..<names.count {
                let index = (start + offset) % names.count
                if names[index].lowercased().hasPrefix(needle) { return index }
            }
            return nil
        }
        return names.firstIndex { $0.lowercased().hasPrefix(needle) }
    }
}

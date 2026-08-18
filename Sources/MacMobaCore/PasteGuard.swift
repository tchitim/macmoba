// Deciding whether a clipboard paste deserves a confirmation prompt.
//
// Pasting into a shell is the one place where clipboard contents execute
// themselves: a trailing newline runs the command whether or not you meant it,
// and text copied off a web page can carry hidden extra lines or escape
// sequences. This is the pure part of that check so it can be unit-tested; the
// alert that uses it lives in the app target.

import Foundation

public struct PasteSummary: Equatable, Sendable {
    /// Lines the paste would produce, ignoring one trailing newline.
    public let lineCount: Int
    public let characterCount: Int
    /// A newline that is not merely the final one — i.e. this paste runs more
    /// than one command.
    public let hasInteriorNewline: Bool
    /// Control characters other than tab/newline, e.g. an embedded ESC that
    /// could drive the terminal rather than feed the shell.
    public let hasControlCharacters: Bool
    /// First few lines, elided, for showing in the confirmation alert.
    public let preview: String

    public var needsConfirmation: Bool { hasInteriorNewline || hasControlCharacters }
}

public enum PasteGuard {
    /// Lines shown in the confirmation preview before eliding the rest.
    static let previewLines = 4
    /// Longest preview line before truncating with an ellipsis.
    static let previewLineWidth = 76

    public static func inspect(_ text: String) -> PasteSummary {
        let normalized = normalizeNewlines(text)
        // One trailing newline is the ordinary "copied a command" case, so it
        // does not by itself count as an extra line.
        var body = normalized
        if body.hasSuffix("\n") { body.removeLast() }
        let lines = body.isEmpty ? [] : body.components(separatedBy: "\n")

        return PasteSummary(
            lineCount: max(1, lines.count),
            characterCount: text.count,
            hasInteriorNewline: lines.count > 1,
            hasControlCharacters: containsControlCharacters(normalized),
            preview: preview(of: lines)
        )
    }

    /// Collapse a multi-line paste into one command line: lines joined by a
    /// single space, blank lines dropped. Used by "Paste as One Line", so a
    /// copied snippet can be reviewed before it runs instead of each line
    /// firing as it arrives.
    public static func singleLine(_ text: String) -> String {
        normalizeNewlines(text)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Internals

    /// CRLF and bare CR both act as line breaks in a paste; fold them to \n so
    /// counting and joining do not have to care which platform copied the text.
    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x09, 0x0a: return false      // tab and newline are expected
            case 0..<0x20, 0x7f: return true   // other C0 controls, and DEL
            default: return false
            }
        }
    }

    private static func preview(of lines: [String]) -> String {
        var shown = lines.prefix(previewLines).map { line -> String in
            let flat = line.replacingOccurrences(of: "\t", with: "    ")
            // Escape sequences would drive the alert's text view; show them as
            // a visible marker instead.
            let visible = String(flat.unicodeScalars.map { scalar -> Character in
                scalar.value < 0x20 || scalar.value == 0x7f ? "␣" : Character(scalar)
            })
            return visible.count > previewLineWidth
                ? String(visible.prefix(previewLineWidth)) + "…"
                : visible
        }
        if lines.count > previewLines {
            shown.append("… and \(lines.count - previewLines) more line(s)")
        }
        return shown.joined(separator: "\n")
    }
}

// Is this a name you can safely rename a file to?
//
// A rename box is the one place a user hands us a string that becomes part of
// a path on someone else's machine. "../etc/passwd" is not a file name, and a
// name with a slash in it is a move to somewhere else — quietly performing it
// would be a surprise at best.

import Foundation

public enum FileNameCheck {
    /// Why a name cannot be used, or nil when it is fine.
    ///
    /// - Parameter existing: the other names in the same folder, so a clash is
    ///   caught before the server refuses (or worse, silently replaces).
    public static func rejection(for rawName: String, existing: Set<String> = [],
                                 currentName: String? = nil) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            return "The name cannot be empty."
        }
        if name == currentName {
            return nil // renaming to the same thing is a no-op, not an error
        }
        if name == "." || name == ".." {
            return "\"\(name)\" is not a name — it means this folder or the one above."
        }
        if name.contains("/") {
            return "A name cannot contain \"/\". To move something, drag it instead."
        }
        // A NUL ends a C string: everything after it would be silently dropped
        // on its way to the server.
        if name.unicodeScalars.contains(where: { $0.value == 0 }) {
            return "The name contains a character that cannot be sent."
        }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            return "The name contains a control character."
        }
        if name.count > 255 {
            return "The name is too long (\(name.count) characters; the limit is 255)."
        }
        if existing.contains(name) {
            return "\"\(name)\" already exists in this folder."
        }
        return nil
    }

    /// What to actually use, once accepted: the trimmed form.
    public static func cleaned(_ rawName: String) -> String {
        rawName.trimmingCharacters(in: .whitespaces)
    }
}

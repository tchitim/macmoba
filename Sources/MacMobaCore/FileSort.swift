// Ordering a file listing.
//
// Its own file with its own tests because sorting is where "obviously right"
// and "actually right" part company: a name comparison that ignores numbers
// puts file10 before file2, a date sort has to cope with servers that report
// no date at all, and every order has to be TOTAL or the list reshuffles
// itself on each refresh.

import Foundation

public enum FileSortKey: String, CaseIterable, Sendable, Identifiable, Codable {
    case name
    case modified
    case size
    case kind

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }

    /// Which direction people actually mean when they pick this.
    ///
    /// Names read best A→Z, but nobody sorts by date to see the oldest file
    /// first — "sort by modified" means "what changed recently".
    public var prefersDescending: Bool {
        switch self {
        case .name, .kind: return false
        case .modified, .size: return true
        }
    }
}

public enum FileSort {
    /// Order `items`.
    ///
    /// - Parameter foldersFirst: keeps directories grouped at the top whatever
    ///   the key is, which is what a transfer pane wants — you navigate with
    ///   the folders and pick from the files.
    public static func sort(_ items: [SFTPItem], by key: FileSortKey,
                            ascending: Bool, foldersFirst: Bool = true) -> [SFTPItem] {
        items.sorted { lhs, rhs in
            if foldersFirst, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            let ordered = compare(lhs, rhs, by: key)
            switch ordered {
            case .orderedSame:
                // Ties break on name, always ascending, so the order is total:
                // two files of the same size must not swap places every time
                // the list reloads.
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .orderedAscending:
                return ascending
            case .orderedDescending:
                return !ascending
            }
        }
    }

    private static func compare(_ lhs: SFTPItem, _ rhs: SFTPItem,
                                by key: FileSortKey) -> ComparisonResult {
        switch key {
        case .name:
            // localizedStandard is the Finder's comparison: case-insensitive
            // and number-aware, so file2 comes before file10.
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            // Directory sizes are meaningless over SFTP (a block count, not
            // the tree's size), so they compare equal and fall through to name.
            if lhs.isDirectory && rhs.isDirectory { return .orderedSame }
            return compareNumbers(lhs.size, rhs.size)
        case .modified:
            // A server that reports no time sorts as oldest rather than
            // jumping to the top of a newest-first list.
            let left = lhs.attributes.mtime ?? 0
            let right = rhs.attributes.mtime ?? 0
            return compareNumbers(UInt64(left), UInt64(right))
        case .kind:
            let left = fileExtension(lhs.name)
            let right = fileExtension(rhs.name)
            let result = left.localizedStandardCompare(right)
            return result
        }
    }

    private static func compareNumbers(_ lhs: UInt64, _ rhs: UInt64) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// The part after the last dot, lower-cased. A leading dot is part of the
    /// name, not an extension: ".bashrc" has no kind, it is called that.
    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

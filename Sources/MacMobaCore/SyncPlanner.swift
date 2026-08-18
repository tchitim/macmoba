// Deciding what a one-way sync copies.
//
// "Make that side look like this one" is easy to get subtly wrong in ways that
// only show up over time: a clock difference that makes every file look newer
// and recopies the lot on every run, a file replaced by an older copy without
// anyone noticing, a folder quietly ignored because something with its name
// already exists.
//
// Nothing here deletes. A sync that removes files at the destination is a
// different, much more dangerous feature, and it is not what these buttons do.

import Foundation

public struct SyncComparison: Sendable {
    /// Missing at the destination, a different size, or newer here.
    public var filesToCopy: [SFTPItem] = []
    /// Same size, not newer — already in step.
    public var unchangedFiles: [SFTPItem] = []
    /// Names in `filesToCopy` whose destination copy is NEWER than the source.
    /// Copying replaces something more recent, so the user is told the count
    /// before anything moves.
    public var replacingNewer: [String] = []
    /// Directories with no counterpart: copied whole.
    public var directoriesToCopyWhole: [SFTPItem] = []
    /// Directories on both sides: compared recursively.
    public var directoriesToDescend: [SFTPItem] = []
    /// A file on one side and a directory on the other. Never guessed at.
    public var typeConflicts: [String] = []

    public var isEmpty: Bool {
        filesToCopy.isEmpty && directoriesToCopyWhole.isEmpty && directoriesToDescend.isEmpty
    }
}

public enum SyncPlanner {
    /// Modification times are only comparable so far.
    ///
    /// SFTP reports whole seconds while a local file has sub-second precision,
    /// and two machines' clocks are never exactly aligned. Without a tolerance
    /// the same unchanged file looks newer on every run and is copied forever.
    public static let defaultToleranceSeconds: Int64 = 2

    public static func compare(source: [SFTPItem], destination: [SFTPItem],
                               toleranceSeconds: Int64 = defaultToleranceSeconds)
        -> SyncComparison {
        var result = SyncComparison()
        let destinationByName = Dictionary(
            destination.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for item in source {
            // Following a symlink would copy whatever it points at, which may
            // be a whole tree or a device.
            if item.isSymlink { continue }
            let other = destinationByName[item.name]

            if item.isDirectory {
                guard let other else {
                    result.directoriesToCopyWhole.append(item)
                    continue
                }
                if other.isDirectory {
                    result.directoriesToDescend.append(item)
                } else {
                    result.typeConflicts.append(item.name)
                }
                continue
            }

            guard let other else {
                result.filesToCopy.append(item)
                continue
            }
            if other.isDirectory {
                result.typeConflicts.append(item.name)
                continue
            }

            let sourceTime = Int64(item.attributes.mtime ?? 0)
            let destinationTime = Int64(other.attributes.mtime ?? 0)
            let sizesDiffer = item.size != other.size
            let sourceIsNewer = sourceTime > destinationTime + toleranceSeconds

            if sizesDiffer || sourceIsNewer {
                result.filesToCopy.append(item)
                if destinationTime > sourceTime + toleranceSeconds {
                    result.replacingNewer.append(item.name)
                }
            } else {
                result.unchangedFiles.append(item)
            }
        }
        return result
    }

    /// A one-line description of what a sync is about to do.
    public static func summary(_ comparison: SyncComparison) -> String {
        var parts: [String] = []
        let files = comparison.filesToCopy.count
        parts.append(files == 1 ? "1 file" : "\(files) files")
        if !comparison.directoriesToCopyWhole.isEmpty {
            parts.append("\(comparison.directoriesToCopyWhole.count) new folder"
                         + (comparison.directoriesToCopyWhole.count == 1 ? "" : "s"))
        }
        var text = "Copy " + parts.joined(separator: " and ") + "."
        if !comparison.replacingNewer.isEmpty {
            let count = comparison.replacingNewer.count
            text += " \(count) would replace a NEWER "
                + (count == 1 ? "file" : "files") + " at the destination."
        }
        if !comparison.typeConflicts.isEmpty {
            text += " \(comparison.typeConflicts.count) skipped"
                + " (a file on one side, a folder on the other)."
        }
        if !comparison.unchangedFiles.isEmpty {
            text += " \(comparison.unchangedFiles.count) already up to date."
        }
        return text
    }
}

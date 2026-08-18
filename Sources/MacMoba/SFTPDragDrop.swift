// Drag support for the SFTP browser.
//
// Dragging a row onto a folder row moves the item server-side. Identity is
// held in the model rather than on the pasteboard, because SwiftUI's `.onDrag`
// does not carry extra representations faithfully — and both ends of an
// in-panel move live in this process anyway.
//
// Dragging out to Finder is NOT supported: downloading on drop needs an
// NSFilePromiseProvider, and neither route works from a SwiftUI List row —
// `.onDrag` never gets asked for its file representation, and a nested AppKit
// drag source never receives the mouse events. Use Download… in the context
// menu instead. (Verified by driving the UI; see README known limitations.)

import AppKit
import MacMobaCore
import SwiftUI
import UniformTypeIdentifiers

/// What an in-panel drag is carrying. Kept in the model rather than on the
/// pasteboard: SwiftUI's `.onDrag` does not preserve extra representations
/// faithfully, and both ends of an in-panel move live in this process anyway.
/// The pasteboard then carries only the file itself, so Finder drops download
/// the file instead of writing a payload blob.
struct SFTPDraggedItem {
    let item: SFTPItem
    let sourceDirectory: String
    let startedAt = Date()

    var isFresh: Bool { Date().timeIntervalSince(startedAt) < 120 }
}

enum SFTPDrag {
    static func utType(for item: SFTPItem) -> UTType {
        if item.isDirectory { return .folder }
        let ext = (item.name as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    /// Icon macOS uses for this file type, for the row and the drag image.
    static func icon(for item: SFTPItem) -> NSImage {
        NSWorkspace.shared.icon(for: utType(for: item))
    }

}

/// Row icon: shows the real file-type icon (also used as the drag image).
struct SFTPItemIcon: View {
    let item: SFTPItem

    var body: some View {
        if item.isSymlink {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        } else {
            Image(nsImage: SFTPDrag.icon(for: item))
                .resizable()
                .frame(width: 18, height: 18)
        }
    }
}

// AppKit file list for the SFTP browser.
//
// A SwiftUI List cannot support dragging a remote file out to Finder: the
// download-on-drop contract needs an NSFilePromiseProvider, and `.onDrag`
// never asks for its file representation. NSTableView vends promises properly,
// so the list is AppKit and the rest of the panel stays SwiftUI.

import AppKit
import MacMobaCore
import SwiftUI
import UniformTypeIdentifiers

struct SFTPFileTable: NSViewRepresentable {
    @ObservedObject var model: SFTPBrowserModel
    var onEdit: (SFTPItem) -> Void
    var onEditWith: (SFTPItem) -> Void
    var onRename: (SFTPItem) -> Void
    var onDelete: (SFTPItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 22
        table.style = .inset
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.menu = context.coordinator.makeMenu()

        // Accept Finder files *and* our own rows: an internal drag carries a
        // file promise, not a fileURL, so the promise types must be registered
        // or the table rejects its own drags.
        table.registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + [.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }
        if context.coordinator.shownItems.map(\.name) != model.items.map(\.name) {
            context.coordinator.shownItems = model.items
            table.reloadData()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                             NSFilePromiseProviderDelegate {
        var parent: SFTPFileTable
        weak var table: NSTableView?
        var shownItems: [SFTPItem] = []
        private let promiseQueue = OperationQueue()

        init(_ parent: SFTPFileTable) {
            self.parent = parent
        }

        private var model: SFTPBrowserModel { parent.model }

        func numberOfRows(in tableView: NSTableView) -> Int { shownItems.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard shownItems.indices.contains(row) else { return nil }
            let item = shownItems[row]
            let cell = NSTableCellView()

            let icon = NSImageView(image: SFTPDrag.icon(for: item))
            icon.translatesAutoresizingMaskIntoConstraints = false
            let name = NSTextField(labelWithString: item.name)
            name.lineBreakMode = .byTruncatingMiddle
            name.translatesAutoresizingMaskIntoConstraints = false
            let detail = NSTextField(labelWithString:
                item.isDirectory ? "" : Self.sizeFormatter.string(fromByteCount: Int64(item.size)))
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            detail.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(icon)
            cell.addSubview(name)
            cell.addSubview(detail)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
                detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let row = table?.selectedRow, shownItems.indices.contains(row) else { return }
            let item = shownItems[row]
            Task { @MainActor in model.selection = item.id }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let row = table?.clickedRow, shownItems.indices.contains(row) else { return }
            let item = shownItems[row]
            Task { @MainActor in model.openItem(item) }
        }

        // MARK: Drag out (file promise)

        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard shownItems.indices.contains(row) else { return nil }
            let item = shownItems[row]
            Task { @MainActor in model.beginDrag(item) }
            let provider = NSFilePromiseProvider(
                fileType: SFTPDrag.utType(for: item).identifier, delegate: self)
            provider.userInfo = item.name
            return provider
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            (provider.userInfo as? String) ?? "download"
        }

        func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            let name = (provider.userInfo as? String) ?? ""
            Task { @MainActor in
                guard let item = model.items.first(where: { $0.name == name }) else {
                    completionHandler(SFTPError.localFile("item disappeared"))
                    return
                }
                do {
                    try await model.downloadForDrag(item, to: url)
                    completionHandler(nil)
                } catch {
                    model.errorMessage = "Download failed: \(error)"
                    completionHandler(error)
                }
            }
        }

        // MARK: Drop in

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            let isInternal = info.draggingSource is NSTableView
            // The table proposes "between rows" by default; retarget onto the
            // folder actually under the pointer so dropping on it means "into".
            let point = tableView.convert(info.draggingLocation, from: nil)
            let hovered = tableView.row(at: point)
            if hovered >= 0, shownItems.indices.contains(hovered), shownItems[hovered].isDirectory {
                tableView.setDropRow(hovered, dropOperation: .on)
                return isInternal ? .move : .copy
            }
            // Anywhere else: upload into the current directory (external only).
            if isInternal { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            let targetFolder: SFTPItem? =
                (op == .on && shownItems.indices.contains(row) && shownItems[row].isDirectory)
                ? shownItems[row] : nil

            // Internal move.
            if info.draggingSource is NSTableView {
                guard let folder = targetFolder else { return false }
                Task { @MainActor in
                    if let dragged = model.consumeDraggedItem() {
                        model.moveItem(dragged, intoFolder: folder)
                    }
                }
                return true
            }

            // Finder upload.
            var urls: [URL] = []
            info.enumerateDraggingItems(options: [], for: tableView,
                                        classes: [NSURL.self], searchOptions: [:]) { item, _, _ in
                if let url = item.item as? URL { urls.append(url) }
            }
            guard !urls.isEmpty else { return false }
            Task { @MainActor in
                let destination = targetFolder.map { model.remotePathForDrag($0) }
                model.uploadItems(urls, destination: destination)
            }
            return true
        }

        // MARK: Context menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        @objc private func menuAction(_ sender: NSMenuItem) {
            guard let row = table?.clickedRow, shownItems.indices.contains(row) else { return }
            let item = shownItems[row]
            let parent = self.parent
            Task { @MainActor in
                switch sender.tag {
                case 0: parent.model.openItem(item)
                case 1: parent.onEdit(item)
                case 2: parent.onEditWith(item)
                case 3: parent.model.download(item)
                case 4: parent.onRename(item)
                case 5: parent.onDelete(item)
                case 6: parent.model.stopEditing(parent.model.remotePathForDrag(item))
                default: break
                }
            }
        }

        private func add(_ menu: NSMenu, _ title: String, _ tag: Int) {
            let entry = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            menu.addItem(entry)
        }

        static let sizeFormatter: ByteCountFormatter = {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return f
        }()
    }
}

extension SFTPFileTable.Coordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = table?.clickedRow, shownItems.indices.contains(row) else { return }
        let item = shownItems[row]
        let editing = model.editSessions[model.remotePathForDrag(item)] != nil

        if item.isDirectory {
            add(menu, "Open", 0)
        } else if editing {
            add(menu, "Open Local Copy", 1)
            add(menu, "Stop Watching", 6)
        } else {
            add(menu, "Edit Locally", 1)
            add(menu, "Edit With…", 2)
        }
        add(menu, "Download…", 3)
        add(menu, "Rename…", 4)
        menu.addItem(.separator())
        add(menu, "Delete…", 5)
    }
}

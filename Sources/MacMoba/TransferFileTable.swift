// The file list inside a transfer pane, as a real NSTableView.
//
// SwiftUI's List cannot do this job here: any gesture on a row swallows the
// click the List needs for selection, so double-click-to-open and click-to-
// select are mutually exclusive (measured: with a double-click gesture on the
// row, 0 of 5 clicks selected anything). AppKit has had all three — single
// click, double click, and a context menu — working together since 1989, and
// the single-pane browser already uses it for exactly that reason.

import AppKit
import MacMobaCore
import SwiftUI

struct TransferFileTable: NSViewRepresentable {
    @ObservedObject var model: TransferPaneModel
    var onRename: (SFTPItem) -> Void
    var onDelete: ([SFTPItem]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 22
        table.style = .inset
        // The whole point of this pane: pick several things, then move them.
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = NSSize(width: 0, height: 2)

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.menu = context.coordinator.makeMenu()

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
        let coordinator = context.coordinator
        if coordinator.shownItems.map(\.name) != model.items.map(\.name) {
            coordinator.shownItems = model.items
            table.reloadData()
        }
        // Follow the model when something else changes the selection — a
        // reload dropping names that are gone, or a transfer finishing.
        let wanted = IndexSet(coordinator.shownItems.enumerated()
            .filter { model.selection.contains($0.element.name) }
            .map(\.offset))
        if table.selectedRowIndexes != wanted {
            coordinator.applyingModelSelection = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            coordinator.applyingModelSelection = false
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: TransferFileTable
        weak var table: NSTableView?
        var shownItems: [SFTPItem] = []
        /// True while we are pushing the model's selection INTO the table, so
        /// the resulting delegate callback does not push it straight back.
        var applyingModelSelection = false

        init(_ parent: TransferFileTable) {
            self.parent = parent
        }

        private var model: TransferPaneModel { parent.model }

        func numberOfRows(in tableView: NSTableView) -> Int { shownItems.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard shownItems.indices.contains(row) else { return nil }
            let item = shownItems[row]
            let cell = NSTableCellView()

            let symbol = item.isDirectory ? "folder.fill"
                : (item.isSymlink ? "arrowshape.turn.up.right" : "doc")
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol,
                                                  accessibilityDescription: nil)
                                   ?? NSImage())
            icon.contentTintColor = item.isDirectory ? .controlAccentColor : .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false

            let name = NSTextField(labelWithString: item.name)
            name.lineBreakMode = .byTruncatingMiddle
            name.translatesAutoresizingMaskIntoConstraints = false

            // Whatever the list is sorted by is what the trailing column shows,
            // so the order on screen is readable rather than mysterious.
            let trailing: String
            if model.sortKey == .modified, let modified = item.modified {
                trailing = Self.dateFormatter.string(from: modified)
            } else if item.isDirectory {
                trailing = ""
            } else {
                trailing = Self.sizeFormatter.string(fromByteCount: Int64(item.size))
            }
            let detail = NSTextField(labelWithString: trailing)
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
                detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor,
                                                constant: 8),
                detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingModelSelection, let table else { return }
            let names = Set(table.selectedRowIndexes.compactMap { row in
                shownItems.indices.contains(row) ? shownItems[row].name : nil
            })
            model.selection = names
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let row = table?.clickedRow, shownItems.indices.contains(row) else { return }
            model.enter(shownItems[row])
        }

        // MARK: Context menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        /// What a menu command applies to.
        ///
        /// Right-clicking inside an existing selection acts on the whole
        /// selection; right-clicking elsewhere acts on that row alone, which
        /// is how every Mac list behaves.
        func targets(forClicked row: Int) -> [SFTPItem] {
            guard shownItems.indices.contains(row) else { return [] }
            let clicked = shownItems[row]
            if model.selection.contains(clicked.name), model.selection.count > 1 {
                return shownItems.filter { model.selection.contains($0.name) }
            }
            return [clicked]
        }

        @objc func menuAction(_ sender: NSMenuItem) {
            guard let row = table?.clickedRow else { return }
            let items = targets(forClicked: row)
            guard let first = items.first else { return }
            switch sender.tag {
            case 0: model.enter(first)
            case 1: parent.onRename(first)
            case 2: parent.onDelete(items)
            case 3: model.refresh()
            default: break
            }
        }

        private func add(_ menu: NSMenu, _ title: String, _ tag: Int) {
            let entry = NSMenuItem(title: title, action: #selector(menuAction(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            menu.addItem(entry)
        }

        static let sizeFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter
        }()
    }
}

extension TransferFileTable.Coordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = table?.clickedRow, shownItems.indices.contains(row) else {
            // Right-clicking empty space still offers the one thing that makes
            // sense there.
            add(menu, "Refresh", 3)
            return
        }
        let items = targets(forClicked: row)
        let item = shownItems[row]

        if item.isDirectory, items.count == 1 {
            add(menu, "Open", 0)
            menu.addItem(.separator())
        }
        // Renaming several things at once has no sensible meaning.
        if items.count == 1 {
            add(menu, "Rename…", 1)
        }
        add(menu, items.count == 1 ? "Delete…" : "Delete \(items.count) Items…", 2)
        menu.addItem(.separator())
        add(menu, "Refresh", 3)
    }
}

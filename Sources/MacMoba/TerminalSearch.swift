// Terminal scrollback search (⌘F). SwiftTerm's own SearchService is internal,
// so matching is done over the public buffer API and navigation uses
// scrollTo(row:) to bring each hit into view.

import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class TerminalSearchModel: ObservableObject {
    struct Match: Identifiable {
        let id = UUID()
        /// Scroll-invariant row index.
        let row: Int
        let line: String
    }

    @Published var query = "" {
        didSet { if query != oldValue { runSearch() } }
    }
    @Published var caseSensitive = false {
        didSet { runSearch() }
    }
    @Published private(set) var matches: [Match] = []
    @Published private(set) var currentIndex = 0

    private weak var pane: TerminalTab?

    func attach(to pane: TerminalTab?) {
        self.pane = pane
        runSearch()
    }

    var summary: String {
        if query.isEmpty { return "" }
        return matches.isEmpty ? "No results" : "\(currentIndex + 1) of \(matches.count)"
    }

    func runSearch() {
        guard let pane, !query.isEmpty else {
            matches = []
            currentIndex = 0
            return
        }
        // Through the seam, so ⌘F works whichever library is drawing. Each
        // line arrives with the row number that engine's scrollTo accepts.
        let needle = caseSensitive ? query : query.lowercased()
        var found: [Match] = []
        for (row, text) in pane.engine.engineTextLines() {
            let haystack = caseSensitive ? text : text.lowercased()
            if haystack.contains(needle) {
                found.append(Match(row: row, line: text.trimmingCharacters(in: .whitespaces)))
            }
        }
        matches = found
        currentIndex = 0
        if !found.isEmpty { scrollToCurrent() }
    }

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
        scrollToCurrent()
    }

    func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        scrollToCurrent()
    }

    func jump(to match: Match) {
        guard let index = matches.firstIndex(where: { $0.id == match.id }) else { return }
        currentIndex = index
        scrollToCurrent()
    }

    private func scrollToCurrent() {
        guard let pane, matches.indices.contains(currentIndex) else { return }
        pane.engine.engineScroll(toRow: matches[currentIndex].row)
    }
}

/// AppKit-backed search field. A SwiftUI TextField cannot reliably take key
/// focus here: the terminal is an AppKit view that holds first responder, so
/// the field must claim it explicitly from the window.
struct SearchFieldView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchFieldView
        init(_ parent: SearchFieldView) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find in scrollback"
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        // Take focus away from the terminal once the bar is on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
}

struct TerminalSearchBar: View {
    @ObservedObject var model: TerminalSearchModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                SearchFieldView(text: $model.query) { model.next() }
                    .frame(height: 24)
                Text(model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
                Toggle("Aa", isOn: $model.caseSensitive)
                    .toggleStyle(.button)
                    .help("Match case")
                Button { model.previous() } label: { Image(systemName: "chevron.up") }
                    .disabled(model.matches.isEmpty)
                    .help("Previous match (⇧⌘G)")
                Button { model.next() } label: { Image(systemName: "chevron.down") }
                    .disabled(model.matches.isEmpty)
                    .help("Next match (⌘G)")
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .help("Close (Esc)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if !model.matches.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.matches.enumerated()), id: \.element.id) { index, match in
                            HStack {
                                Text(match.line)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(index == model.currentIndex
                                        ? Color.accentColor.opacity(0.25) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { model.jump(to: match) }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .background(.bar)
    }
}

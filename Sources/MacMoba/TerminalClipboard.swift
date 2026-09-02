// Copy/paste behaviour on top of SwiftTerm — MobaXterm's clipboard ergonomics.
//
// Three things SwiftTerm does not do on its own:
//   * copy-on-select, so a dragged selection is already in the clipboard;
//   * right-click / middle-click paste, so you never reach for ⌘V;
//   * a confirmation before a paste that would run more than one command.
//
// The behaviour is identical for SSH panes and local shell tabs, which are
// different SwiftTerm classes, so the logic lives here and each subclass is a
// thin set of overrides.

import AppKit
import MacMobaCore
import SwiftTerm

// MARK: - Preferences

@MainActor
final class ClipboardPrefs: ObservableObject {
    static let shared = ClipboardPrefs()

    @Published var copyOnSelect: Bool {
        didSet { UserDefaults.standard.set(copyOnSelect, forKey: "copyOnSelect") }
    }
    /// Right-click and middle-click paste, the way xterm and MobaXterm do.
    /// When off, right-click opens a Copy/Paste context menu instead.
    @Published var mousePaste: Bool {
        didSet { UserDefaults.standard.set(mousePaste, forKey: "mousePaste") }
    }
    @Published var warnMultilinePaste: Bool {
        didSet { UserDefaults.standard.set(warnMultilinePaste, forKey: "warnMultilinePaste") }
    }

    private init() {
        let defaults = UserDefaults.standard
        // All three default to on; `object(forKey:)` distinguishes "never set"
        // from "set to false", which `bool(forKey:)` cannot.
        copyOnSelect = defaults.object(forKey: "copyOnSelect") as? Bool ?? true
        mousePaste = defaults.object(forKey: "mousePaste") as? Bool ?? true
        warnMultilinePaste = defaults.object(forKey: "warnMultilinePaste") as? Bool ?? true
    }
}

// MARK: - Shared behaviour

@MainActor
enum TerminalClipboard {
    /// Copy the live selection after a drag or double-click, if the user wants
    /// selection to mean copy. Called from `mouseUp`, where the selection has
    /// settled; a plain click clears the selection first so it is a no-op.
    static func copyOnSelectIfEnabled(_ view: TerminalView) {
        guard ClipboardPrefs.shared.copyOnSelect,
              let text = view.getSelection(), !text.isEmpty else { return }
        write(text)
    }

    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func clipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// PNG bytes when the clipboard holds an image and no text — a screenshot,
    /// not a copied web selection (those carry both, and text wins).
    static func clipboardImagePNG() -> Data? {
        let pasteboard = NSPasteboard.general
        guard clipboardText()?.isEmpty != false else { return nil }
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    /// Paste, asking first when the clipboard would run more than one command.
    /// The alert is a window sheet rather than `runModal()`: a global modal
    /// steals the keyboard from the terminal you are typing into.
    static func requestPaste(into view: TerminalView) {
        // A pasted screenshot in an SSH pane goes to the remote as a file, and
        // its path lands in the prompt — how you hand an image to an agent
        // running over there (cmux workflow, SSH edition).
        if let tab = view.terminalDelegate as? TerminalTab,
           tab.config.sessionKind.authenticatesOverSSH,
           let png = clipboardImagePNG() {
            tab.pasteImageToRemote(png)
            return
        }
        guard let text = clipboardText(), !text.isEmpty else { return }
        let summary = PasteGuard.inspect(text)
        guard ClipboardPrefs.shared.warnMultilinePaste, summary.needsConfirmation,
              let window = view.window else {
            send(text, to: view)
            return
        }
        confirm(text, summary: summary, window: window) { [weak view] choice in
            guard let view else { return }
            switch choice {
            case .paste: send(text, to: view)
            case .oneLine: send(PasteGuard.singleLine(text), to: view)
            case .cancel: break
            }
        }
    }

    /// Paste with newlines collapsed to spaces, no confirmation — the point of
    /// the command is that nothing runs until you press Return yourself.
    static func pasteAsOneLine(into view: TerminalView) {
        guard let text = clipboardText(), !text.isEmpty else { return }
        send(PasteGuard.singleLine(text), to: view)
    }

    /// Write text to the session as a paste. Bracketed paste mode is honoured
    /// so editors and shells that support it treat the text as data rather than
    /// as typed keys (this is what stops a pasted newline from running in zsh).
    static func send(_ text: String, to view: TerminalView) {
        guard !text.isEmpty else { return }
        let bracketed = view.getTerminal().bracketedPasteMode
        if bracketed { view.send(data: EscapeSequences.bracketedPasteStart[0...]) }
        view.send(txt: text)
        if bracketed { view.send(data: EscapeSequences.bracketedPasteEnd[0...]) }
    }

    // MARK: Confirmation

    enum PasteChoice { case paste, oneLine, cancel }

    private static func confirm(
        _ text: String,
        summary: PasteSummary,
        window: NSWindow,
        completion: @escaping (PasteChoice) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = summary.hasInteriorNewline
            ? "Paste \(summary.lineCount) lines into this terminal?"
            : "The clipboard contains control characters."
        var info = summary.hasInteriorNewline
            ? "Each line runs as its own command as soon as it arrives.\n\n"
            : "Control characters are interpreted by the terminal, not the shell.\n\n"
        info += summary.preview
        alert.informativeText = info
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Paste as One Line")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t warn me again"

        alert.beginSheetModal(for: window) { response in
            if alert.suppressionButton?.state == .on {
                ClipboardPrefs.shared.warnMultilinePaste = false
            }
            switch response {
            case .alertFirstButtonReturn: completion(.paste)
            case .alertSecondButtonReturn: completion(.oneLine)
            default: completion(.cancel)
            }
        }
    }

    // MARK: Context menu

    static func contextMenu(for view: TerminalView) -> NSMenu {
        let hasClipboard = clipboardText()?.isEmpty == false
        let menu = NSMenu()
        // Enablement is set here rather than left to AppKit: automatic
        // validation routes through NSUserInterfaceValidations, and SwiftTerm's
        // implementation rejects every selector it does not know about — which
        // includes our "Paste as One Line".
        menu.autoenablesItems = false
        add(to: menu, "Copy", #selector(TerminalView.copy(_:)),
            enabled: view.selectionActive, target: view)
        add(to: menu, "Paste", #selector(TerminalView.paste(_:)),
            enabled: hasClipboard, target: view)
        add(to: menu, "Paste as One Line", #selector(ClipboardTerminalView.pasteAsOneLine(_:)),
            enabled: hasClipboard, target: view)
        menu.addItem(.separator())
        add(to: menu, "Select All", #selector(NSView.selectAll(_:)),
            enabled: true, target: view)
        return menu
    }

    private static func add(to menu: NSMenu, _ title: String, _ action: Selector,
                            enabled: Bool, target: TerminalView) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.isEnabled = enabled
        menu.addItem(item)
    }
}

// MARK: - Subclasses

/// SSH panes. `LocalProcessTerminalView` is a separate SwiftTerm subclass, so
/// the same overrides are repeated below rather than shared by inheritance.
final class ClipboardTerminalView: TerminalView {
    /// Clicking a terminal must point the keyboard at it.
    ///
    /// AppKit does not move first responder on a click by itself, and
    /// SwiftTerm's mouseDown does not ask for it either — panes got the
    /// keyboard only when their host view was first built. That was enough
    /// while a tab held one kind of thing; in a split with a remote desktop,
    /// whoever took first responder last kept it, so clicking back onto a shell
    /// changed nothing and the shell looked dead.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        TerminalClipboard.copyOnSelectIfEnabled(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard ClipboardPrefs.shared.mousePaste, event.modifierFlags.intersection(
            [.command, .control, .option, .shift]).isEmpty else {
            super.rightMouseDown(with: event)
            return
        }
        TerminalClipboard.requestPaste(into: self)
    }

    /// Middle-click paste, as in xterm. SwiftTerm ignores the middle button, so
    /// there is nothing to fall through to.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, ClipboardPrefs.shared.mousePaste else {
            super.otherMouseDown(with: event)
            return
        }
        TerminalClipboard.requestPaste(into: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        TerminalClipboard.contextMenu(for: self)
    }

    override func paste(_ sender: Any) {
        TerminalClipboard.requestPaste(into: self)
    }

    @objc func pasteAsOneLine(_ sender: Any?) {
        TerminalClipboard.pasteAsOneLine(into: self)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(pasteAsOneLine(_:)) {
            return TerminalClipboard.clipboardText()?.isEmpty == false
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// Local shell tabs — same behaviour, different SwiftTerm base class.
final class ClipboardLocalTerminalView: LocalProcessTerminalView {
    /// Clicking a terminal must point the keyboard at it.
    ///
    /// AppKit does not move first responder on a click by itself, and
    /// SwiftTerm's mouseDown does not ask for it either — panes got the
    /// keyboard only when their host view was first built. That was enough
    /// while a tab held one kind of thing; in a split with a remote desktop,
    /// whoever took first responder last kept it, so clicking back onto a shell
    /// changed nothing and the shell looked dead.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    /// The tab this view belongs to, so a keystroke at a dead shell can reach
    /// the two ways out of one. Weak: the tab owns the view.
    weak var owner: LocalTerminalTab?

    /// Once the shell has exited there is no PTY to write to, so the only keys
    /// that mean anything are Return (start a new shell) and Esc (close the
    /// pane). Without this they land in a dead process and nothing happens —
    /// which is exactly what "Esc doesn't close it" looked like.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if owner?.handleKeyAtDeadShell(Array(data)) == true { return }
        super.send(source: source, data: data)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        TerminalClipboard.copyOnSelectIfEnabled(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard ClipboardPrefs.shared.mousePaste, event.modifierFlags.intersection(
            [.command, .control, .option, .shift]).isEmpty else {
            super.rightMouseDown(with: event)
            return
        }
        TerminalClipboard.requestPaste(into: self)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, ClipboardPrefs.shared.mousePaste else {
            super.otherMouseDown(with: event)
            return
        }
        TerminalClipboard.requestPaste(into: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        TerminalClipboard.contextMenu(for: self)
    }

    override func paste(_ sender: Any) {
        TerminalClipboard.requestPaste(into: self)
    }

    @objc func pasteAsOneLine(_ sender: Any?) {
        TerminalClipboard.pasteAsOneLine(into: self)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(pasteAsOneLine(_:)) {
            return TerminalClipboard.clipboardText()?.isEmpty == false
        }
        return super.validateUserInterfaceItem(item)
    }
}

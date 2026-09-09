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
import UniformTypeIdentifiers
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

    /// An image on the clipboard, with the extension to give it.
    ///
    /// Two shapes count. A copied image FILE — from Photos or Finder — arrives
    /// as a file URL, and those bytes are sent as they are. A copied image
    /// with no file behind it, such as a screenshot, arrives as raw data and
    /// becomes PNG.
    static func clipboardImage() -> (data: Data, fileExtension: String)? {
        let pasteboard = NSPasteboard.general

        // Files first, and BEFORE the text check below. A file on the
        // pasteboard also carries its path as text, so that check rejected
        // every copied picture and the path was pasted instead — a path on
        // this Mac, which means nothing on the machine at the other end.
        //
        // The original bytes rather than a PNG conversion: re-encoding a
        // photo's JPEG can multiply its size several times over, and this is
        // about to go up an SSH connection.
        if let url = imageFileOnPasteboard(pasteboard),
           let data = try? Data(contentsOf: url) {
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
            return (data, ext)
        }

        // A path written as plain text, with no file URL beside it.
        //
        // Copying a picture in Photos produces exactly this: the string is a
        // path inside the photo library and there is no file URL to find, so
        // the check above sees nothing and the path gets typed at the remote,
        // where it names nothing. Narrow on purpose — one line, absolute, an
        // existing file, and an image by content type — so ordinary text that
        // happens to mention a path is still pasted as text.
        let pathAsText = clipboardText().flatMap(imagePathWrittenAsText)
        if let url = pathAsText {
            if let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
                return (data, ext)
            }
            // Named an image and could not be opened. A photo library is
            // protected by macOS privacy, so this is the likely everyday case
            // — and falling through silently would paste the path again, which
            // is the failure being fixed. The raw image data below is tried
            // next, since a picture usually rides along with its path.
            PasteTrace.log("image path on clipboard could not be read: \(url.path)")
        }

        // Raw image data. Normally only when there is no text — a copied web
        // selection carries both and the text is what was meant — but text
        // that is merely a path to a picture is not text anybody wants typed.
        guard clipboardText()?.isEmpty != false || pathAsText != nil else { return nil }
        if let png = pasteboard.data(forType: .png) { return (png, "png") }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }

    /// The first pasteboard file that is actually an image.
    ///
    /// Asked by content type rather than by extension, so a file named
    /// without one, or named misleadingly, is judged by what it is.
    private static func imageFileOnPasteboard(_ pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: options) as? [URL] else { return nil }
        return urls.first { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]))?
                .contentType?.conforms(to: .image) == true
        }
    }

    /// A single absolute path naming an image file, or nil.
    private static func imagePathWrittenAsText(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), trimmed.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: trimmed)
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              values.contentType?.conforms(to: .image) == true else { return nil }
        return url
    }

    /// Everything the pasteboard is offering, for when a paste does the wrong
    /// thing and the reason is which flavour won.
    static func describePasteboard() -> String {
        let pb = NSPasteboard.general
        let types = (pb.types ?? []).map(\.rawValue).joined(separator: ", ")
        let text = pb.string(forType: .string)
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
        return "types=[\(types)] "
            + "string=\(text.map { "\"\($0.prefix(120))\"" } ?? "nil") "
            + "fileURLs=\(urls.map(\.lastPathComponent))"
    }

    /// Kept for callers that only ask "is there a picture".
    static func clipboardImagePNG() -> Data? { clipboardImage()?.data }

    /// Paste, asking first when the clipboard would run more than one command.
    /// The alert is a window sheet rather than `runModal()`: a global modal
    /// steals the keyboard from the terminal you are typing into.
    /// - Parameter allowImageUpload: whether a screenshot on the clipboard may
    ///   be uploaded to the remote.
    ///
    ///   False for the mouse shortcuts. Right-click and middle-click paste are
    ///   the xterm idiom, and that idiom is about TEXT — but the image branch
    ///   below writes a file on someone else's machine and types its path, with
    ///   no confirmation, which is not what a stray right-click should mean.
    ///   Most people expect a right-click to open a menu; this one uploaded a
    ///   screenshot that had been sitting on the clipboard since some earlier
    ///   ⇧⌘4, and left it there for good. Deliberate pastes — ⌘V and the menu
    ///   item — still upload, because that is the feature working as intended.
    static func requestPaste(into view: TerminalView, allowImageUpload: Bool = true) {
        PasteTrace.log("requestPaste (SwiftTerm path), images=\(allowImageUpload), "
                       + "text=\(clipboardText()?.count ?? -1) chars")
        // A pasted screenshot in an SSH pane goes to the remote as a file, and
        // its path lands in the prompt — how you hand an image to an agent
        // running over there (cmux workflow, SSH edition).
        // Through the engine wrapper, which is the view's delegate now. The
        // direct `as? TerminalTab` this replaces had been quietly failing for
        // every pane since the wrapper was introduced.
        if allowImageUpload,
           let tab = (view.terminalDelegate as? SwiftTermEngine)?.engineOwner,
           tab.config.sessionKind.authenticatesOverSSH,
           let image = clipboardImage() {
            tab.pasteImageToRemote(image.data, fileExtension: image.fileExtension)
            return
        }
        // An image is on the clipboard, this path was allowed to upload it, and
        // no pane could be identified — which is what the broken cast looked
        // like from the outside: nothing happened, no error, for months. Say it
        // rather than fall through in silence.
        if allowImageUpload, clipboardImagePNG() != nil,
           (view.terminalDelegate as? SwiftTermEngine)?.engineOwner == nil {
            NSLog("MacMoba: image paste ignored — no owning pane for this view")
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
        TerminalClipboard.requestPaste(into: self, allowImageUpload: false)
    }

    /// Middle-click paste, as in xterm. SwiftTerm ignores the middle button, so
    /// there is nothing to fall through to.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, ClipboardPrefs.shared.mousePaste else {
            super.otherMouseDown(with: event)
            return
        }
        TerminalClipboard.requestPaste(into: self, allowImageUpload: false)
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
        // Same as the SSH view's: mouse paste is text. A local shell never
        // uploads anyway, but the two subclasses are already duplicated by
        // hand and letting them differ here is how they start drifting.
        TerminalClipboard.requestPaste(into: self, allowImageUpload: false)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, ClipboardPrefs.shared.mousePaste else {
            super.otherMouseDown(with: event)
            return
        }
        TerminalClipboard.requestPaste(into: self, allowImageUpload: false)
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

/// Traces which paste path actually ran.
///
/// "Paste does nothing" has several possible shapes — the gesture never
/// reaching the app, the app deciding there is nothing to paste, or the text
/// reaching the terminal and the terminal ignoring it — and from outside they
/// are identical. Each entry point says which one it is.
///
///     defaults write dev.macmoba.MacMoba ghosttyDebugLog -bool true
enum PasteTrace {
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "ghosttyDebugLog")
    }

    /// Beside the session logs, because unified logging could not be relied
    /// on to show any of this.
    ///
    /// Two rounds of diagnosis produced no output at all from `log show` on
    /// the reporter's machine — not the app's lines, not even the ones the
    /// terminal library emits — so a trace that only reaches os_log is a
    /// trace nobody can read. A file is dull and it works.
    static var logURL: URL {
        SessionLogger.directory.appendingPathComponent("MacMoba-Paste.log")
    }

    static func log(_ what: String) {
        guard enabled else { return }
        NSLog("ghostty: paste — %@", what)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  \(what)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: SessionLogger.directory,
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - Engine-based context menu
//
// The menu above targets SwiftTerm's view and its selectors, which only exists
// on one of the two engines. This builds the same menu against the seam, so a
// libghostty pane gets a real right-click menu rather than an empty one.

/// Carries the menu's actions. AppKit needs an `@objc` target, and the engine
/// is a protocol existential, so this sits between them.
@MainActor
final class ClipboardMenuTarget: NSObject {
    private let engine: any TerminalEngineView

    init(engine: any TerminalEngineView) {
        self.engine = engine
        super.init()
    }

    @objc func copySelection(_ sender: Any?) {
        guard let text = engine.engineSelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func pasteClipboard(_ sender: Any?) {
        PasteTrace.log(TerminalClipboard.describePasteboard())
        // Images first, exactly as the SwiftTerm path does: a screenshot in an
        // SSH pane is uploaded and its path typed, which is how an image is
        // handed to an agent running over there. This branch was missing here,
        // so pasting a picture into a libghostty pane did nothing whatsoever.
        if let tab = engine.engineOwner,
           tab.config.sessionKind.authenticatesOverSSH,
           let image = TerminalClipboard.clipboardImage() {
            PasteTrace.log("menu Paste: \(image.data.count) byte .\(image.fileExtension) -> upload")
            tab.pasteImageToRemote(image.data, fileExtension: image.fileExtension)
            return
        }
        guard let text = TerminalClipboard.clipboardText(), !text.isEmpty else {
            PasteTrace.log("menu Paste: clipboard held neither text nor an image")
            return
        }
        PasteTrace.log("menu Paste: \(text.count) chars to \(engine.engineName)")
        engine.enginePaste(text)
    }

    @objc func pasteAsOneLine(_ sender: Any?) {
        guard let text = TerminalClipboard.clipboardText(), !text.isEmpty else { return }
        engine.enginePaste(PasteGuard.singleLine(text))
    }

    @objc func selectAll(_ sender: Any?) {
        engine.engineSelectAll()
    }

    func menu() -> NSMenu {
        let hasClipboard = TerminalClipboard.clipboardText()?.isEmpty == false
        let menu = NSMenu()
        // Set explicitly for the same reason the SwiftTerm menu does it:
        // automatic validation rejects selectors it does not recognise.
        menu.autoenablesItems = false
        add(menu, "Copy", #selector(copySelection(_:)), engine.engineHasSelection)
        add(menu, "Paste", #selector(pasteClipboard(_:)), hasClipboard)
        add(menu, "Paste as One Line", #selector(pasteAsOneLine(_:)), hasClipboard)
        // Only where the engine actually has one; libghostty does not, and an
        // item that quietly does nothing is worse than a shorter menu.
        if engine.engineCanSelectAll {
            menu.addItem(.separator())
            add(menu, "Select All", #selector(selectAll(_:)), true)
        }
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }
}

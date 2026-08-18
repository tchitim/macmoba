// Confirmation for a macro that MultiExec will fan out to every session.
//
// A macro with "press Return" on, plus broadcast, executes on every connected
// host the moment the shortcut is pressed — no shell prompt in between to
// notice the mistake. This shows what runs and where before it happens.

import AppKit
import MacMobaCore

@MainActor
enum MacroBroadcastPrompt {
    /// Sessions listed in full before collapsing to a count; a 40-host fleet
    /// should not produce a 40-line alert.
    private static let listedTargets = 8

    static func confirm(
        macro: MacroConfig,
        targets: [TerminalTab],
        window: NSWindow?,
        onSuppress: @escaping () -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = macro.sendReturn
            ? "Run “\(macro.name)” on \(targets.count) sessions?"
            : "Type “\(macro.name)” into \(targets.count) sessions?"
        alert.informativeText = """
            MultiExec is on, so this goes to every connected session:

            \(targetList(targets))

            \(PasteGuard.inspect(macro.command).preview)
            """
        alert.addButton(withTitle: macro.sendReturn
                        ? "Run on \(targets.count) Sessions" : "Send to \(targets.count) Sessions")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = macro.sendReturn
        }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if alert.suppressionButton?.state == .on { onSuppress() }
            completion(response == .alertFirstButtonReturn)
        }
        // Sheet rather than runModal(): a global modal takes the keyboard away
        // from the terminal, which is the bug that removed the logging alert.
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private static func targetList(_ targets: [TerminalTab]) -> String {
        var lines = targets.prefix(listedTargets).map { pane in
            "  • \(pane.config.username)@\(pane.config.host):\(pane.config.port)"
        }
        if targets.count > listedTargets {
            lines.append("  • … and \(targets.count - listedTargets) more")
        }
        return lines.joined(separator: "\n")
    }
}

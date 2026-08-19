// A logger that keeps the few lines worth keeping.
//
// Copy and paste does not cross a Screen Sharing session in either direction,
// and everything checkable from the outside looks right: the clipboard monitor
// is compiled in, it starts on connect, and received text is written straight
// to the general pasteboard. What is left is whether those code paths actually
// run, and the library says so itself — it logs when the monitor notices a
// local copy, and when clipboard text arrives from the server.
//
// Those are ordinary `logDebug` calls made unconditionally; the filtering lives
// inside the stock logger. So substituting one that keeps clipboard lines costs
// nothing and needs no setting turned on, and it answers the question the
// outside cannot: which half is silent.

import AppKit
import Foundation
import RoyalVNCKit

final class VNCDiagnosticLogger: VNCLogger, @unchecked Sendable {
    var isDebugLoggingEnabled = false

    private let lock = NSLock()
    private var lines: [String] = []
    private var sentToServer = 0
    private var receivedFromServer = 0

    /// Everything else is dropped as it arrives — this is a diagnostic, not a
    /// log file, and a VNC session debug-logs every frame.
    func logDebug(_ message: String) {
        guard message.localizedCaseInsensitiveContains("clipboard") else { return }
        lock.lock()
        defer { lock.unlock() }
        // Two directions, two distinct messages in the library.
        if message.localizedCaseInsensitiveContains("monitor") {
            sentToServer += 1
        } else if message.localizedCaseInsensitiveContains("received") {
            receivedFromServer += 1
        }
        lines.append(message)
        if lines.count > 40 { lines.removeFirst() }
    }

    func logInfo(_ message: String) {}
    func logWarning(_ message: String) { note("warning: \(message)") }
    func logError(_ message: String) { note("error: \(message)") }

    private func note(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(message)
        if lines.count > 40 { lines.removeFirst() }
    }

    var report: String {
        lock.lock()
        defer { lock.unlock() }
        return """
        clipboard sent to server (local copy noticed): \(sentToServer)
        clipboard received from server: \(receivedFromServer)
        local clipboard survives Latin-1: \(Self.localClipboardIsLatin1)
        recent lines:
        \(lines.isEmpty ? "  (none)" : lines.map { "  " + $0 }.joined(separator: "\n"))
        """
    }

    /// RFB's clipboard messages carry Latin-1 and nothing else, so anything
    /// outside it — Chinese, an em dash, an emoji — cannot be expressed. The
    /// library turns a failed conversion into empty data, which is why pasting
    /// such text onto the remote silently does nothing.
    private static var localClipboardIsLatin1: String {
        guard let text = NSPasteboard.general.string(forType: .string) else { return "no text" }
        return text.data(using: .isoLatin1) == nil ? "NO — cannot be sent by RFB" : "yes"
    }
}

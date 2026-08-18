// Session logging — MobaXterm writes terminal output to a file for later
// review. Escape sequences are stripped so the log reads as plain text.

import Foundation

/// Thread-safe holder for the active logger.
///
/// The logger is switched on from the main thread but consumed on the SSH
/// event-loop thread. Without synchronisation that reader can keep observing
/// the old (nil) value, which silently produced empty logs.
final class LoggerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SessionLogger?

    var current: SessionLogger? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ logger: SessionLogger?) {
        lock.lock()
        value = logger
        lock.unlock()
    }
}

final class SessionLogger {
    let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.macmoba.sessionlog")

    /// Where logs are written. Defaults to ~/Documents/MacMoba Logs/ but the
    /// user can point this anywhere (external disk, synced folder, /dev/null-ish
    /// scratch space) via Settings.
    static let directoryDefaultsKey = "sessionLogDirectory"

    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: directoryDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultDirectory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMoba Logs", isDirectory: true)
    }

    static func setDirectory(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: directoryDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: directoryDefaultsKey)
        }
    }

    init?(sessionName: String) {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let safeName = sessionName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let file = dir.appendingPathComponent(
            "\(safeName)-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "")).log")

        // 0600: session output can contain anything the server printed
        // (config files, tokens, command output), so keep it owner-only —
        // same posture as vault.json.
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file) else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: dir.path)
        self.url = file
        self.handle = handle
        write(header: "=== MacMoba session log: \(sessionName) — \(Date()) ===\n")
    }

    private func write(header: String) {
        queue.async { [handle] in try? handle.write(contentsOf: Data(header.utf8)) }
    }

    /// Existing on-screen history, written once when logging starts.
    func appendScrollback(_ text: String) {
        guard !text.isEmpty else { return }
        queue.async { [handle] in
            let body = "--- scrollback before logging started ---\n" + text
                + "\n--- live from here ---\n"
            try? handle.write(contentsOf: Data(body.utf8))
        }
    }

    func append(_ data: Data) {
        queue.async { [handle] in
            let cleaned = SessionLogger.stripEscapes(data)
            guard !cleaned.isEmpty else { return }
            try? handle.write(contentsOf: cleaned)
        }
    }

    func close() {
        queue.async { [handle] in
            try? handle.write(contentsOf: Data("\n=== ended \(Date()) ===\n".utf8))
            try? handle.close()
        }
    }

    /// Remove ANSI/CSI/OSC sequences so the log is readable as text.
    static func stripEscapes(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]
            if byte == 0x1b {  // ESC
                let next = data.index(after: i)
                guard next < data.endIndex else { break }
                switch data[next] {
                case 0x5b:  // CSI: ESC [ ... final byte in @-~
                    var j = data.index(after: next)
                    while j < data.endIndex, !(0x40...0x7e).contains(data[j]) {
                        j = data.index(after: j)
                    }
                    i = j < data.endIndex ? data.index(after: j) : data.endIndex
                case 0x5d:  // OSC: ESC ] ... BEL or ST
                    var j = data.index(after: next)
                    while j < data.endIndex, data[j] != 0x07 {
                        if data[j] == 0x1b, data.index(after: j) < data.endIndex,
                           data[data.index(after: j)] == 0x5c {
                            j = data.index(after: j)
                            break
                        }
                        j = data.index(after: j)
                    }
                    i = j < data.endIndex ? data.index(after: j) : data.endIndex
                default:    // two-byte escape
                    i = data.index(after: next)
                }
                continue
            }
            // Keep printable text plus newline/tab; drop other control bytes
            // (including CR, which would otherwise overwrite lines in editors).
            if byte >= 0x20 || byte == 0x0a || byte == 0x09 {
                out.append(byte)
            }
            i = data.index(after: i)
        }
        return out
    }
}

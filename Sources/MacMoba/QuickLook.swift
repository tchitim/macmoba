// Previewing a downloaded file with the system's Quick Look.
//
// A remote file has no local URL to hand to QLPreviewPanel until it is fetched,
// and the browser is SwiftUI with no NSResponder in the chain to own the panel.
// `qlmanage -p` is the documented, dependency-free way to raise the same
// preview the spacebar gives in Finder — the browser downloads to a temp copy
// and points it here.

import AppKit

enum QuickLook {
    static func preview(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        // qlmanage is chatty on stderr even when it works; keep it out of the log.
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Fall back to just opening it — better than nothing if qlmanage is
            // unavailable for some reason.
            NSWorkspace.shared.open(url)
        }
    }
}

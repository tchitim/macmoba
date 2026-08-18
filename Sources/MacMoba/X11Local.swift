// The Mac side of X11 forwarding: is a local X server (XQuartz) running, and
// what is its magic cookie? The parsing lives in MacMobaCore.XAuthority; this
// just finds the file and reads the environment.

import Foundation
import MacMobaCore

enum X11Local {
    /// True when XQuartz looks like it is up — its unix socket exists or DISPLAY
    /// is set. Not a guarantee it accepts TCP; that is the user's XQuartz
    /// setting (`nolisten_tcp`).
    static var isXServerRunning: Bool {
        FileManager.default.fileExists(atPath: "/tmp/.X11-unix/X0")
            || !(ProcessInfo.processInfo.environment["DISPLAY"] ?? "").isEmpty
    }

    /// The local display number from $DISPLAY, defaulting to 0.
    static var localDisplayNumber: Int {
        let display = ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0"
        return X11Forwarding.displayNumber(from: display) ?? 0
    }

    /// The Mac's MIT-MAGIC-COOKIE-1 for the local display, so the remote app can
    /// authenticate to XQuartz. Nil if there is no Xauthority file (a trusted
    /// setup may not need one).
    static func cookie() -> String? {
        let env = ProcessInfo.processInfo.environment
        let path = env["XAUTHORITY"]
            ?? (env["HOME"].map { $0 + "/.Xauthority" })
            ?? (NSHomeDirectory() + "/.Xauthority")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return XAuthority.cookie(forDisplay: localDisplayNumber, in: XAuthority.parse(data))
    }
}

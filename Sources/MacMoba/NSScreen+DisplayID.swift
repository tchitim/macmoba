import AppKit

extension NSScreen {
    /// The CoreGraphics display this screen is, or 0 if AppKit will not say.
    ///
    /// Screens have to be identified by this rather than by their position in
    /// `NSScreen.screens`: that array is renumbered whenever a display is
    /// plugged in or removed, so an index stored when a session connected can
    /// later point at a different physical display.
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }
}

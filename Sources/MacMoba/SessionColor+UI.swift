// Rendering a Core SessionColor as a SwiftUI Color. SessionColor lives in
// MacMobaCore and stays free of SwiftUI, so the bridge belongs here.

import MacMobaCore
import SwiftUI

extension SessionColor {
    /// The swatch colour, or nil for `.none` (callers fall back to `.accentColor`).
    var swiftUIColor: Color? {
        guard let rgb else { return nil }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

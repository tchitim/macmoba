// A small fixed palette for tagging sessions by colour.
//
// A named palette rather than free hex on purpose: the editor becomes a row of
// swatches instead of a colour well, the values are stable across machines, and
// there is a sensible "no colour" that falls back to the app's own tint. The
// hex here is what the UI renders; SessionColor stays in Core and knows nothing
// about SwiftUI, so both the app and any test can reason about it.

import Foundation

public enum SessionColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case gray
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case purple
    case pink

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "Default"
        case .gray: return "Gray"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    /// sRGB "RRGGBB" for rendering, or nil for `.none` (use the app's tint).
    /// Values are picked to read on both light and dark sidebars.
    public var hex: String? {
        switch self {
        case .none: return nil
        case .gray: return "8E8E93"
        case .red: return "FF3B30"
        case .orange: return "FF9500"
        case .yellow: return "FFCC00"
        case .green: return "34C759"
        case .teal: return "30B0C7"
        case .blue: return "0A84FF"
        case .purple: return "AF52DE"
        case .pink: return "FF2D55"
        }
    }

    /// The red/green/blue components in 0...1, or nil for `.none`.
    public var rgb: (red: Double, green: Double, blue: Double)? {
        guard let hex else { return nil }
        func channel(_ start: Int) -> Double {
            let i = hex.index(hex.startIndex, offsetBy: start)
            let j = hex.index(i, offsetBy: 2)
            return Double(Int(hex[i..<j], radix: 16) ?? 0) / 255.0
        }
        return (channel(0), channel(2), channel(4))
    }
}

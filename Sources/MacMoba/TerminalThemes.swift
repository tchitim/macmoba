// Terminal colour schemes (MobaXterm ships a set of these).
// SwiftTerm wants 16 ANSI colours as 16-bit components, plus native
// foreground/background NSColors for the view chrome.

import AppKit
import SwiftTerm
import SwiftUI

struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    /// 16 ANSI colours as #rrggbb: 0-7 normal, 8-15 bright.
    let ansi: [String]
    let background: String
    let foreground: String
    let cursor: String

    static func == (a: TerminalTheme, b: TerminalTheme) -> Bool { a.id == b.id }

    // MARK: - Conversion

    private static func components(_ hex: String) -> (UInt16, UInt16, UInt16) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        // SwiftTerm uses 16-bit channels; scale 8-bit values up.
        let r = UInt16((value >> 16) & 0xff) * 257
        let g = UInt16((value >> 8) & 0xff) * 257
        let b = UInt16(value & 0xff) * 257
        return (r, g, b)
    }

    private static func nsColor(_ hex: String) -> NSColor {
        let (r, g, b) = components(hex)
        return NSColor(srgbRed: CGFloat(r) / 65535, green: CGFloat(g) / 65535,
                       blue: CGFloat(b) / 65535, alpha: 1)
    }

    var swiftTermColors: [SwiftTerm.Color] {
        ansi.map { hex in
            let (r, g, b) = Self.components(hex)
            return SwiftTerm.Color(red: r, green: g, blue: b)
        }
    }

    func apply(to view: TerminalView) {
        view.installColors(swiftTermColors)
        view.nativeBackgroundColor = Self.nsColor(background)
        view.nativeForegroundColor = Self.nsColor(foreground)
        view.caretColor = Self.nsColor(cursor)
        view.needsDisplay = true
    }

    var backgroundColor: NSColor { Self.nsColor(background) }

    // MARK: - Built-ins

    static let all: [TerminalTheme] = [
        TerminalTheme(
            id: "default", name: "MacMoba Dark",
            ansi: ["#000000", "#cc0403", "#19cb00", "#cecb00", "#0d73cc", "#cb1ed1", "#0dcdcd", "#dddddd",
                   "#767676", "#f2201f", "#23fd00", "#fffd00", "#1a8fff", "#fd28ff", "#14ffff", "#ffffff"],
            background: "#000000", foreground: "#dddddd", cursor: "#dddddd"),
        TerminalTheme(
            id: "solarized-dark", name: "Solarized Dark",
            ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                   "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"],
            background: "#002b36", foreground: "#839496", cursor: "#93a1a1"),
        TerminalTheme(
            id: "solarized-light", name: "Solarized Light",
            ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                   "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"],
            background: "#fdf6e3", foreground: "#657b83", cursor: "#586e75"),
        TerminalTheme(
            id: "nord", name: "Nord",
            ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                   "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"],
            background: "#2e3440", foreground: "#d8dee9", cursor: "#d8dee9"),
        TerminalTheme(
            id: "dracula", name: "Dracula",
            ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                   "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"],
            background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2"),
        TerminalTheme(
            id: "github-light", name: "GitHub Light",
            ansi: ["#24292e", "#d73a49", "#28a745", "#dbab09", "#0366d6", "#5a32a3", "#0598bc", "#6a737d",
                   "#959da5", "#cb2431", "#22863a", "#b08800", "#005cc5", "#5a32a3", "#3192aa", "#d1d5da"],
            background: "#ffffff", foreground: "#24292e", cursor: "#24292e"),
    ]

    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? all[0]
    }

    // MARK: - Auto (match system appearance) (P2-11)

    /// The pseudo-theme that follows the system: dark mode gets the house dark
    /// theme, light mode a readable light one.
    static let autoID = "auto"

    /// Resolve a picker selection to a concrete theme. "auto" maps by the
    /// current appearance; any real id passes through unchanged.
    static func resolve(id: String, darkMode: Bool) -> TerminalTheme {
        guard id == autoID else { return theme(id: id) }
        return theme(id: darkMode ? "default" : "github-light")
    }
}

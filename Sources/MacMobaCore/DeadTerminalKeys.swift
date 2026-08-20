// What a keystroke means in a terminal whose connection has gone.
//
// Nothing can be typed into a dead session, so the few keys that still do
// something have to be unambiguous. Enter reconnects in place — the habit
// every terminal user already has — and Escape closes the pane, because the
// other thing you want from a dead session is to be rid of it.
//
// The test is on the WHOLE keystroke, not on whether it contains the byte.
// Escape is also the first byte of every arrow key and function key (`ESC [ A`),
// so "contains 0x1b" would close the pane whenever someone pressed Up looking
// for their last command.

import Foundation

public enum DeadTerminalKey: Equatable {
    case reconnect
    case close
    case ignore

    /// Decide from the exact bytes SwiftTerm hands over for one keystroke.
    public static func action(for bytes: [UInt8]) -> DeadTerminalKey {
        switch bytes {
        case [0x0d], [0x0a]: return .reconnect   // Return, and Enter on a numeric keypad
        case [0x1b]: return .close               // Escape alone, not a sequence starting with it
        default: return .ignore
        }
    }
}

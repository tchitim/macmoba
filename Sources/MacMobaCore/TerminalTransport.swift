// What a terminal pane needs from whatever is carrying it.
//
// SSH and Telnet are wildly different protocols, but from the pane's point of
// view they are the same three things: send what was typed, tell the far end
// the window changed, and hang up. Keeping that as a protocol is what lets a
// Telnet session use the existing pane — with its splits, broadcast input,
// logging and search — instead of growing a parallel tab type.

import Foundation

public protocol TerminalTransport: AnyObject, Sendable {
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    func close()
}

extension SSHConnection: TerminalTransport {}

extension SerialConnection: TerminalTransport {}

// Who receives broadcast input.
//
// MultiExec used to be all-or-nothing: every connected pane, everywhere. Once
// panes can be taken out of it, one question has a wrong answer that is easy
// to ship — what happens when you type into a pane you have EXCLUDED. Sending
// nowhere would mean a terminal that silently ignores you, so the pane you are
// typing in always receives its own keystrokes.

import Foundation

public struct BroadcastPane: Equatable, Sendable {
    public var id: UUID
    public var isConnected: Bool
    /// Whether the user has left this pane in the broadcast group.
    public var receivesBroadcast: Bool

    public init(id: UUID, isConnected: Bool, receivesBroadcast: Bool) {
        self.id = id
        self.isConnected = isConnected
        self.receivesBroadcast = receivesBroadcast
    }
}

public enum BroadcastPolicy {
    /// Which panes a keystroke typed in `origin` should reach.
    ///
    /// - Every connected pane still in the group, in the order given.
    /// - Plus the originating pane, even when it has been excluded: typing
    ///   into a terminal must always reach that terminal.
    /// - Never a disconnected pane; there is nothing to write to.
    public static func targets(typedIn origin: UUID?, panes: [BroadcastPane]) -> [UUID] {
        var result: [UUID] = []
        for pane in panes where pane.isConnected {
            if pane.receivesBroadcast || pane.id == origin {
                result.append(pane.id)
            }
        }
        return result
    }

    /// True when the group is smaller than everything available, i.e. the
    /// user has taken something out and the UI should say so.
    public static func isPartial(_ panes: [BroadcastPane]) -> Bool {
        let connected = panes.filter(\.isConnected)
        guard !connected.isEmpty else { return false }
        return connected.contains { !$0.receivesBroadcast }
    }

    /// How many connected panes a keystroke would actually reach, for the
    /// confirmation shown before a macro goes out.
    public static func reach(_ panes: [BroadcastPane]) -> Int {
        panes.filter { $0.isConnected && $0.receivesBroadcast }.count
    }
}

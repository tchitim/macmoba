// The shape of a tab's split, in a form that survives quitting.
//
// Reopening the sessions you had open is not the same as reopening the WINDOW
// you had: three shells beside a remote desktop came back as four unrelated
// tabs, and rebuilding the arrangement by hand every morning is exactly the
// work a session manager exists to remove.
//
// Only the session id is stored, never a connection: a restored pane dials
// afresh, the same as opening it from the sidebar. What is worth keeping is
// the arrangement.

import Foundation

public indirect enum PaneLayout: Codable, Equatable, Sendable {
    case leaf(sessionID: String)
    /// The deliberate gap beside a lone pane in a grid.
    case empty
    case split(vertical: Bool, first: PaneLayout, second: PaneLayout)

    /// Drop leaves whose session no longer exists, collapsing any split left
    /// with one side — a session deleted since last launch should cost its
    /// pane, not the layout around it.
    ///
    /// Returns nil when nothing is left worth opening. A layout of nothing but
    /// gaps counts as nothing: restoring it would produce a tab you cannot
    /// type into and did not ask for.
    public func pruned(keeping available: Set<String>) -> PaneLayout? {
        switch self {
        case .leaf(let id):
            return available.contains(id) ? self : nil
        case .empty:
            return nil
        case .split(let vertical, let first, let second):
            switch (first.pruned(keeping: available), second.pruned(keeping: available)) {
            case (let a?, let b?): return .split(vertical: vertical, first: a, second: b)
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (nil, nil): return nil
            }
        }
    }

    /// Every session id this layout would open, in the order it would open them.
    public var sessionIDs: [String] {
        switch self {
        case .leaf(let id): return [id]
        case .empty: return []
        case .split(_, let first, let second): return first.sessionIDs + second.sessionIDs
        }
    }
}

/// Every tab a window had, with its arrangement.
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public var tabs: [PaneLayout]

    public init(tabs: [PaneLayout]) {
        self.tabs = tabs
    }

    /// The layout to restore: each tab pruned to what still exists, and tabs
    /// left with nothing dropped entirely.
    public func restorable(available: [String]) -> WorkspaceLayout {
        let present = Set(available)
        return WorkspaceLayout(tabs: tabs.compactMap { $0.pruned(keeping: present) })
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data?) -> WorkspaceLayout? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(WorkspaceLayout.self, from: data)
    }

    /// What an older version saved: a flat list of sessions, one tab each.
    /// Read so that updating does not lose the workspace someone had open.
    public static func fromSessionIDs(_ ids: [String]) -> WorkspaceLayout {
        WorkspaceLayout(tabs: ids.map { .leaf(sessionID: $0) })
    }
}

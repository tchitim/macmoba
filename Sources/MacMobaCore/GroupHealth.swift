// One line about a folder's health, for when the folder is closed.
//
// Collapsing a folder hides its members' status lights — which is exactly when
// you most want to know whether anything in there is down. Rolling the members
// up into a single mark keeps that answer visible without opening it.
//
// The rule is deliberately asymmetric: anything down is worth a mark, and
// everything-fine is worth a quiet one, but "nothing has been checked" earns
// nothing at all. A folder full of grey dots is noise, and a light that means
// "no information" is the kind that teaches people to ignore lights.

import Foundation

public enum GroupHealth: Equatable {
    /// At least one member failed its last check.
    case down(count: Int)
    /// Every member that was checked answered.
    case allUp
    /// Nothing in the folder has been checked yet, or nothing in it is checkable.
    case unknown

    public static func summary(of statuses: [Reachability?]) -> GroupHealth {
        let downCount = statuses.filter { status in
            if case .down = status { return true }
            return false
        }.count
        if downCount > 0 { return .down(count: downCount) }
        let anyUp = statuses.contains { status in
            if case .up = status { return true }
            return false
        }
        return anyUp ? .allUp : .unknown
    }
}

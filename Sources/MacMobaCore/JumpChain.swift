// Resolving `ssh -J b,a` — a session reached through a chain of bastions.
//
// A session's `proxyJump` names one bastion; that bastion may have a proxyJump
// of its own, and so on. Following the links gives the hops to open, and the
// order matters: the outermost bastion (the one this Mac can actually reach) is
// opened first, then each inner hop is tunnelled through the previous, until the
// last hop is the one that dials the target.
//
// The two ways this goes wrong — a loop (a → b → a) and a runaway chain — are
// handled here so the connection code can trust the list it gets.

import Foundation

public enum JumpChain {
    /// Sessions are not expected to nest bastions dozens deep; this is a guard
    /// against a malformed vault, not a real limit.
    public static let maxDepth = 16

    /// The bastions to open to reach `session`, outermost first (the one to
    /// connect to directly) and innermost last (the one that dials `session`).
    /// Empty when the session connects directly.
    ///
    /// A cycle or a missing reference stops the walk cleanly, returning the hops
    /// gathered so far rather than looping or throwing — a broken jump setting
    /// should degrade, not wedge the app.
    public static func resolve(for session: SessionConfig,
                               sessions: [SessionConfig]) -> [SessionConfig] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysByFirst: ())
        var chain: [SessionConfig] = []
        var visited: Set<String> = [session.id]
        var current = session

        while let jumpID = current.proxyJump, !jumpID.isEmpty {
            guard visited.insert(jumpID).inserted,          // stop on a cycle
                  let jump = byID[jumpID],                   // stop on a dangling ref
                  chain.count < maxDepth else { break }
            // Following proxyJump from the target gives direct-jump first; the
            // connection needs outermost first, so each new hop goes on the front.
            chain.insert(jump, at: 0)
            current = jump
        }
        return chain
    }
}

private extension Dictionary {
    /// Build from pairs, keeping the first value for a duplicate key rather than
    /// trapping the way `Dictionary(uniqueKeysWithValues:)` does.
    init(_ pairs: [(Key, Value)], uniquingKeysByFirst _: Void) {
        self.init(pairs, uniquingKeysWith: { first, _ in first })
    }
}

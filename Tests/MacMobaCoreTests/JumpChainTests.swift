import XCTest

@testable import MacMobaCore

final class JumpChainTests: XCTestCase {
    private func session(_ id: String, jump: String? = nil) -> SessionConfig {
        var s = SessionConfig(id: id, name: id, host: "\(id).example", username: "u")
        s.proxyJump = jump
        return s
    }

    func testNoJumpIsEmpty() {
        let target = session("t")
        XCTAssertEqual(JumpChain.resolve(for: target, sessions: [target]), [])
    }

    func testSingleJump() {
        let bastion = session("a")
        let target = session("t", jump: "a")
        let chain = JumpChain.resolve(for: target, sessions: [target, bastion])
        XCTAssertEqual(chain.map(\.id), ["a"])
    }

    /// target -J b (b -J a): the app connects a first (outermost, reachable from
    /// here), then b through a, then the target through b.
    func testTwoHopsAreOutermostFirst() {
        let a = session("a")               // reachable from this Mac
        let b = session("b", jump: "a")    // reached through a
        let target = session("t", jump: "b")
        let chain = JumpChain.resolve(for: target, sessions: [target, a, b])
        XCTAssertEqual(chain.map(\.id), ["a", "b"])
    }

    func testThreeHops() {
        let a = session("a")
        let b = session("b", jump: "a")
        let c = session("c", jump: "b")
        let target = session("t", jump: "c")
        let chain = JumpChain.resolve(for: target, sessions: [target, a, b, c])
        XCTAssertEqual(chain.map(\.id), ["a", "b", "c"])
    }

    /// A loop must not hang: a -> b -> a stops when it revisits a.
    func testCycleStopsCleanly() {
        let a = session("a", jump: "b")
        let b = session("b", jump: "a")
        let target = session("t", jump: "a")
        let chain = JumpChain.resolve(for: target, sessions: [target, a, b])
        // a, then b, then a-again is refused: [b, a] outermost-first.
        XCTAssertEqual(Set(chain.map(\.id)), ["a", "b"])
        XCTAssertLessThanOrEqual(chain.count, 2)
    }

    func testSelfReferenceStops() {
        var t = session("t")
        t.proxyJump = "t"
        XCTAssertEqual(JumpChain.resolve(for: t, sessions: [t]), [])
    }

    func testDanglingReferenceStops() {
        let target = session("t", jump: "ghost")
        XCTAssertEqual(JumpChain.resolve(for: target, sessions: [target]), [])
    }

    func testDepthIsCapped() {
        var sessions: [SessionConfig] = []
        for i in 0..<40 {
            sessions.append(session("h\(i)", jump: i == 0 ? nil : "h\(i - 1)"))
        }
        let target = session("t", jump: "h39")
        let chain = JumpChain.resolve(for: target, sessions: sessions + [target])
        XCTAssertLessThanOrEqual(chain.count, JumpChain.maxDepth)
    }
}

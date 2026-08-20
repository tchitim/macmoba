import XCTest
@testable import MacMobaCore

final class TunnelHostsTests: XCTestCase {

    private func session(_ name: String, _ kind: SessionKind) -> SessionConfig {
        var session = SessionConfig(name: name, host: "192.0.2.5", username: "u")
        session.kind = kind.rawValue
        return session
    }

    func testOnlySSHSpeakingSessionsCanCarryATunnel() {
        let all = [session("shell", .ssh), session("desktop", .vnc), session("windows", .rdp),
                   session("port", .serial), session("page", .web), session("roaming", .mosh)]
        XCTAssertEqual(TunnelHosts.eligible(in: all).map(\.name), ["shell", "roaming"])
    }

    /// Mosh is included because its config IS an SSH login — that is how mosh
    /// starts — so a forward opens over the same credentials and jump chain.
    func testMoshCounts() {
        XCTAssertEqual(TunnelHosts.eligible(in: [session("m", .mosh)]).count, 1)
    }

    func testASavedTunnelPointingAtSomethingElseIsNotEligible() {
        let desktop = session("desktop", .vnc)
        XCTAssertFalse(TunnelHosts.isEligible(sessionID: desktop.id, in: [desktop]))
    }

    func testADeletedSessionIsNotEligible() {
        XCTAssertFalse(TunnelHosts.isEligible(sessionID: "gone", in: [session("shell", .ssh)]))
    }

    func testAnSSHSessionIsEligible() {
        let shell = session("shell", .ssh)
        XCTAssertTrue(TunnelHosts.isEligible(sessionID: shell.id, in: [shell]))
    }
}

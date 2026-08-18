import XCTest
import CMacMobaRDP

/// Lifetime of the RDP session object, which is shared between the caller and
/// the connection thread.
///
/// The bug these cover: `macmoba_rdp_free` used to wait three seconds for the
/// connection thread and then free the FreeRDP context regardless. When the
/// wait expired — which is exactly what happens when the network has gone away,
/// because `freerdp_disconnect` is then slow — the thread went straight back to
/// reading `context->abortEvent` on freed memory and took the process down with
/// a bus error inside `freerdp_shall_disconnect_context`.
final class RDPLifetimeTests: XCTestCase {

    /// Counts `onRelease` calls, and can pin the connection thread in place.
    /// Addressed through a raw pointer so the C side can reach it without any
    /// Swift object lifetime being involved.
    private final class ReleaseProbe {
        let released = DispatchSemaphore(value: 0)
        /// Raised once the connection thread is parked inside the state
        /// callback, i.e. once it is provably unable to finish.
        let threadParked = DispatchSemaphore(value: 0)
        private let letThreadGo = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        private var parkOnDisconnect = false

        /// Makes the connection thread block when it reports disconnection.
        /// This is how the test stands in for a slow `freerdp_disconnect` on a
        /// network that has gone away, which is the real-world cause of the
        /// caller giving up on the join.
        func parkThreadOnDisconnect() {
            lock.lock(); parkOnDisconnect = true; lock.unlock()
        }

        func releaseThread() { letThreadGo.signal() }

        func recordState(_ state: MacMobaRDPState) {
            lock.lock()
            let shouldPark = parkOnDisconnect && state == MACMOBA_RDP_STATE_DISCONNECTED
            lock.unlock()
            guard shouldPark else { return }
            threadParked.signal()
            letThreadGo.wait()
        }

        func recordRelease() {
            lock.lock(); count += 1; lock.unlock()
            released.signal()
        }

        var releaseCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    private static func probe(_ userData: UnsafeMutableRawPointer?) -> ReleaseProbe? {
        guard let userData else { return nil }
        return Unmanaged<ReleaseProbe>.fromOpaque(userData).takeUnretainedValue()
    }

    private static let onRelease: MacMobaRDPReleaseCallback = { userData in
        probe(userData)?.recordRelease()
    }

    private static let onState: MacMobaRDPStateCallback = { userData, state, _ in
        probe(userData)?.recordState(state)
    }

    /// A port nothing listens on, so the connection is refused immediately.
    /// These tests do not want a slow connection — the stall that matters is
    /// arranged through the state callback, where it can be controlled exactly.
    private static let deadHost = "127.0.0.1"
    private static let deadPort: Int32 = 1

    private func makeSession(probe: ReleaseProbe) -> OpaquePointer? {
        macmoba_rdp_create(Unmanaged.passUnretained(probe).toOpaque(),
                           nil, Self.onState, nil, Self.onRelease)
    }

    /// The reference handed to `macmoba_rdp_create` comes back exactly once,
    /// for a session that never started a connection thread.
    func testReleasesOwnerReferenceWithoutConnecting() {
        let probe = ReleaseProbe()
        guard let rdp = makeSession(probe: probe) else {
            return XCTFail("could not create session")
        }
        XCTAssertEqual(probe.releaseCount, 0, "released before the owner let go")

        macmoba_rdp_free(rdp)
        XCTAssertEqual(probe.releaseCount, 1)
    }

    /// The case that used to crash: `free` is called while the connection
    /// thread cannot finish, so the join times out. The session must stay alive
    /// under the thread's own reference and be torn down later, by the thread.
    ///
    /// Under the old code the assertion below is what failed — the caller freed
    /// the context on the way out, and the still-running thread then read it.
    func testSessionOutlivesOwnerWhenThreadCannotBeJoined() {
        let probe = ReleaseProbe()
        probe.parkThreadOnDisconnect()
        guard let rdp = makeSession(probe: probe) else {
            return XCTFail("could not create session")
        }

        XCTAssertTrue(macmoba_rdp_connect(rdp, Self.deadHost, Self.deadPort,
                                          "user", "password", nil, 1024, 768, 0, true, nil, nil, 0, nil, 0),
                      "connection thread did not start")

        // Wait for the thread to be provably stuck before letting go of it, so
        // the join is guaranteed to time out rather than merely likely to.
        XCTAssertEqual(probe.threadParked.wait(timeout: .now() + 30), .success,
                       "connection thread never reached the state callback")

        let started = Date()
        macmoba_rdp_free(rdp)
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(waited, 2.5, "expected free to have waited for the stuck thread")

        // The owner has let go, but the thread is still inside the session, so
        // nothing may have been torn down yet.
        XCTAssertEqual(probe.releaseCount, 0,
                       "session was torn down while the connection thread was still in it")

        // Once the thread unwinds it must complete the teardown by itself.
        probe.releaseThread()
        XCTAssertEqual(probe.released.wait(timeout: .now() + 30), .success,
                       "session was never released; the thread leaked it")
        XCTAssertEqual(probe.releaseCount, 1, "released more than once")
    }

    /// Repeated create/connect/free cycles must balance exactly — one release
    /// each, no double-free, nothing left over.
    func testReferenceCountingBalancesAcrossCycles() {
        let probes = (0..<4).map { _ in ReleaseProbe() }
        for probe in probes {
            guard let rdp = makeSession(probe: probe) else {
                return XCTFail("could not create session")
            }
            _ = macmoba_rdp_connect(rdp, Self.deadHost, Self.deadPort,
                                    "user", "password", nil, 1024, 768, 0, true, nil, nil, 0, nil, 0)
            macmoba_rdp_free(rdp)
        }

        for (index, probe) in probes.enumerated() {
            let arrived = probe.released.wait(timeout: .now() + 30)
            XCTAssertEqual(arrived, .success, "session \(index) was never released")
            XCTAssertEqual(probe.releaseCount, 1, "session \(index) released \(probe.releaseCount) times")
        }
    }
}

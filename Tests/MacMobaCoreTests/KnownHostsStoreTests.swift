import XCTest
@testable import MacMobaCore

/// The pinned-identity store, shared by SSH host keys and RDP certificates.
final class KnownHostsStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(_ name: String = "hosts.json") -> KnownHostsStore {
        KnownHostsStore(fileURL: directory.appendingPathComponent(name))
    }

    /// Reopens the store once what is on disk satisfies `until`.
    ///
    /// Waiting for the file to merely *exist* is not enough: writes are flushed
    /// on a background queue, so after the first save the file is already there
    /// and a later change can still be in flight. That produced a test which
    /// passed alone and failed in the full suite, where the queue is busier.
    private func reopened(_ name: String = "hosts.json",
                          until satisfied: (KnownHostsStore) -> Bool) throws -> KnownHostsStore {
        let url = directory.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let store = KnownHostsStore(fileURL: url)
            if satisfied(store) { return store }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return KnownHostsStore(fileURL: url)
    }

    func testPinsAndRecallsAFingerprint() throws {
        let store = makeStore()
        XCTAssertNil(store.storedFingerprint(host: "example.com", port: 22))

        store.store(fingerprint: "SHA256:abc", host: "example.com", port: 22)
        XCTAssertEqual(store.storedFingerprint(host: "example.com", port: 22), "SHA256:abc")

        // Same host, different port is a different server.
        XCTAssertNil(store.storedFingerprint(host: "example.com", port: 2222))
    }

    func testSurvivesReopening() throws {
        makeStore().store(fingerprint: "SHA256:abc", host: "example.com", port: 22)
        let again = try reopened { $0.storedFingerprint(host: "example.com", port: 22) != nil }
        XCTAssertEqual(again.storedFingerprint(host: "example.com", port: 22), "SHA256:abc")
    }

    /// Forgetting has to reach disk, not just memory — otherwise a revoked host
    /// comes back at the next launch.
    func testForgettingIsPersisted() throws {
        let store = makeStore()
        store.store(fingerprint: "SHA256:abc", host: "example.com", port: 22)
        store.store(fingerprint: "SHA256:def", host: "other.com", port: 22)

        store.remove(host: "example.com", port: 22)
        XCTAssertNil(store.storedFingerprint(host: "example.com", port: 22))
        XCTAssertEqual(store.storedFingerprint(host: "other.com", port: 22), "SHA256:def",
                       "removing one entry must not disturb the others")

        let again = try reopened {
            $0.storedFingerprint(host: "other.com", port: 22) == "SHA256:def"
                && $0.storedFingerprint(host: "example.com", port: 22) == nil
        }
        XCTAssertNil(again.storedFingerprint(host: "example.com", port: 22),
                     "the removal never reached disk")
        XCTAssertEqual(again.storedFingerprint(host: "other.com", port: 22), "SHA256:def")
    }

    func testRemovingSomethingAbsentIsHarmless() {
        let store = makeStore()
        store.store(fingerprint: "SHA256:abc", host: "example.com", port: 22)
        store.remove(host: "never-seen.com", port: 22)
        XCTAssertEqual(store.allEntries().count, 1)
    }

    func testListsEverythingSortedByHostThenPort() {
        let store = makeStore()
        store.store(fingerprint: "b", host: "beta.com", port: 22)
        store.store(fingerprint: "a2", host: "alpha.com", port: 2222)
        store.store(fingerprint: "a1", host: "alpha.com", port: 22)

        let entries = store.allEntries()
        XCTAssertEqual(entries.map(\.host), ["alpha.com", "alpha.com", "beta.com"])
        XCTAssertEqual(entries.map(\.port), [22, 2222, 22])
        XCTAssertEqual(entries.map(\.fingerprint), ["a1", "a2", "b"])
    }

    /// The key is "host:port" and a bare IPv6 address is full of colons, so
    /// splitting on the first one would report host "" and lose the entry.
    func testIPv6AddressesRoundTripThroughTheKey() {
        let store = makeStore()
        store.store(fingerprint: "SHA256:v6", host: "::1", port: 22)
        store.store(fingerprint: "SHA256:v6b", host: "fe80::1ff:fe23:4567:890a", port: 2222)

        XCTAssertEqual(store.storedFingerprint(host: "::1", port: 22), "SHA256:v6")

        let entries = store.allEntries()
        XCTAssertEqual(entries.count, 2)
        let localhost = entries.first { $0.fingerprint == "SHA256:v6" }
        XCTAssertEqual(localhost?.host, "::1")
        XCTAssertEqual(localhost?.port, 22)

        let linkLocal = entries.first { $0.fingerprint == "SHA256:v6b" }
        XCTAssertEqual(linkLocal?.host, "fe80::1ff:fe23:4567:890a")
        XCTAssertEqual(linkLocal?.port, 2222)

        // And the listing has to agree with removal, or the UI's Forget button
        // would silently do nothing for these hosts.
        store.remove(host: "::1", port: 22)
        XCTAssertNil(store.storedFingerprint(host: "::1", port: 22))
        XCTAssertEqual(store.allEntries().count, 1)
    }

    /// A hand-edited file is expected — this was JSON people edited themselves
    /// before there was any UI.
    func testMalformedKeysAreSkippedRatherThanCrashing() throws {
        let url = directory.appendingPathComponent("hand-edited.json")
        let json = """
        {"good.com:22":"SHA256:ok","no-port":"SHA256:junk","bad.com:notanumber":"SHA256:junk"}
        """
        try Data(json.utf8).write(to: url)

        let store = KnownHostsStore(fileURL: url)
        let entries = store.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.host, "good.com")
        // Lookups still work for the entries that do parse.
        XCTAssertEqual(store.storedFingerprint(host: "good.com", port: 22), "SHA256:ok")
    }

    func testUnreadableFileStartsEmptyInsteadOfFailing() {
        let store = KnownHostsStore(
            fileURL: directory.appendingPathComponent("does-not-exist.json"))
        XCTAssertTrue(store.allEntries().isEmpty)
    }
}

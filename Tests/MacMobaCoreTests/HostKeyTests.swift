// Host key verification tests against the local test server (port 2299).

import Foundation
import XCTest

@testable import MacMobaCore

final class HostKeyTests: XCTestCase {
    static let host = "127.0.0.1"
    static let port = 2299

    private func serverAvailable() -> Bool {
        #if canImport(Darwin)
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(Self.port).bigEndian
        inet_pton(AF_INET, Self.host, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func testSession() -> SessionConfig {
        SessionConfig(
            name: "test", host: Self.host, port: Self.port,
            username: "test", authType: "password", password: "secret"
        )
    }

    final class MemoryStore: HostKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: String] = [:]

        func storedFingerprint(host: String, port: Int) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return entries["\(host):\(port)"]
        }

        func store(fingerprint: String, host: String, port: Int) {
            lock.lock()
            entries["\(host):\(port)"] = fingerprint
            lock.unlock()
        }

        func seed(_ fingerprint: String, host: String, port: Int) {
            store(fingerprint: fingerprint, host: host, port: port)
        }
    }

    final class PromptLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(fingerprint: String, stored: String?)] = []

        func record(_ fingerprint: String, _ stored: String?) {
            lock.lock()
            calls.append((fingerprint, stored))
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.count
        }
    }

    private func connectShell(_ verification: HostKeyVerification) async throws -> SSHConnection {
        try await SSHConnection.connect(
            config: testSession(), hostKeys: verification,
            onData: { _ in }, onExit: { _ in }
        )
    }

    func testFirstTrustThenPinned() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let store = MemoryStore()
        let log = PromptLog()
        let verification = HostKeyVerification(store: store) { _, _, fp, keyType, stored, decision in
            log.record(fp, stored)
            XCTAssertTrue(fp.hasPrefix("SHA256:"))
            XCTAssertFalse(keyType.isEmpty)
            decision(true)
        }

        // 1st connect: unknown key → prompt fires, key gets pinned.
        let conn1 = try await connectShell(verification)
        conn1.close()
        XCTAssertEqual(log.count, 1)
        XCTAssertNil(log.calls[0].stored)
        let pinned = store.storedFingerprint(host: Self.host, port: Self.port)
        XCTAssertNotNil(pinned)

        // 2nd connect: fingerprint matches the pin → no prompt.
        let conn2 = try await connectShell(verification)
        conn2.close()
        XCTAssertEqual(log.count, 1)
    }

    func testMismatchPromptAndRejection() async throws {
        try XCTSkipUnless(serverAvailable(), "no SSH test server on \(Self.host):\(Self.port)")
        let store = MemoryStore()
        store.seed("SHA256:DEFINITELY-NOT-THE-REAL-KEY", host: Self.host, port: Self.port)
        let log = PromptLog()
        let verification = HostKeyVerification(store: store) { _, _, fp, _, stored, decision in
            log.record(fp, stored)
            decision(false) // refuse the changed key
        }

        do {
            let conn = try await connectShell(verification)
            conn.close()
            XCTFail("expected connection to be rejected")
        } catch {
            // Rejection surfaces as hostKeyRejected or as a closed-transport auth error.
        }
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.calls[0].stored, "SHA256:DEFINITELY-NOT-THE-REAL-KEY")
        // Refusing must not overwrite the pin.
        XCTAssertEqual(store.storedFingerprint(host: Self.host, port: Self.port),
                       "SHA256:DEFINITELY-NOT-THE-REAL-KEY")
    }
}

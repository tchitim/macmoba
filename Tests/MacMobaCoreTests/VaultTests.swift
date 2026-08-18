import Foundation
import XCTest

@testable import MacMobaCore

final class VaultTests: XCTestCase {
    private func tempVaultURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macmoba-test-\(UUID().uuidString)")
            .appendingPathComponent("vault.json")
    }

    func testCreateSaveUnlockRoundtrip() throws {
        let url = tempVaultURL()
        let v1 = Vault(fileURL: url)
        XCTAssertEqual(v1.status, .none)
        try v1.create(masterPassword: "correct-horse")

        var data = try v1.getData()
        data.sessions.append(SessionConfig(
            id: "1", name: "srv", host: "10.0.0.1", port: 22,
            username: "root", authType: "password", password: "p@ss"
        ))
        try v1.save(data)

        let v2 = Vault(fileURL: url)
        XCTAssertEqual(v2.status, .locked)
        let loaded = try v2.unlock(masterPassword: "correct-horse")
        XCTAssertEqual(loaded.sessions.count, 1)
        XCTAssertEqual(loaded.sessions[0].password, "p@ss")
        XCTAssertEqual(loaded.sessions[0].host, "10.0.0.1")
    }

    func testWrongPasswordRejected() throws {
        let url = tempVaultURL()
        let v1 = Vault(fileURL: url)
        try v1.create(masterPassword: "right-password")

        let v2 = Vault(fileURL: url)
        XCTAssertThrowsError(try v2.unlock(masterPassword: "wrong-password")) { error in
            XCTAssertEqual(error as? VaultError, .wrongPassword)
        }
    }

    func testNoPlaintextOnDisk() throws {
        let url = tempVaultURL()
        let v = Vault(fileURL: url)
        try v.create(masterPassword: "master-pw")
        var data = try v.getData()
        data.sessions.append(SessionConfig(
            name: "secret-server", host: "192.168.77.66",
            username: "admin", password: "hunter2-plaintext"
        ))
        try v.save(data)

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("hunter2-plaintext"))
        XCTAssertFalse(raw.contains("192.168.77.66"))
        XCTAssertFalse(raw.contains("secret-server"))
    }

    /// The exact bytes below were produced by the Electron/Node version
    /// (src/vault.js) with master password "correct-horse". Opening them here
    /// proves the two implementations share one vault format.
    func testCrossCompatWithNodeVault() throws {
        let nodeVaultJSON = #"""
        {"v":1,"kdf":"scrypt","salt":"el1suj54XZnRxhHFyJ4HBg==","iv":"eMEdnMaFC1eafUIX","tag":"ma0OC1egrtjhImnisoE3PQ==","ct":"zGBhrbx21C7N1iJvNpZ0dVgjVHMIyg8NvyJtPfGk31Y6ETkFNN+rXnRVSJafgyZxU+kpoo/yE7XPdHKSHJHLZW+m30sYqp6g4w8VeO+dPrrM0T2jGaR3BFPGmuJUjxEIVHBgZgG7WQjB2QOQcOKncpcXoeheu2PESuAZpO/tK18UdjzCu9OaY9c6KVYaXprHUnaITWAVGEh47cHI"}
        """#
        let url = tempVaultURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try nodeVaultJSON.write(to: url, atomically: true, encoding: .utf8)

        let v = Vault(fileURL: url)
        let data = try v.unlock(masterPassword: "correct-horse")
        XCTAssertEqual(data.sessions.count, 1)
        XCTAssertEqual(data.sessions[0].name, "node-made")
        XCTAssertEqual(data.sessions[0].host, "10.9.8.7")
        XCTAssertEqual(data.sessions[0].port, 2222)
        XCTAssertEqual(data.sessions[0].password, "sup3r-s3cret")

        // and the reverse: re-save with Swift, ensure format fields intact
        var newData = data
        newData.sessions[0].name = "swift-modified"
        try v.save(newData)
        let reread = try Vault(fileURL: url).unlock(masterPassword: "correct-horse")
        XCTAssertEqual(reread.sessions[0].name, "swift-modified")
    }
}

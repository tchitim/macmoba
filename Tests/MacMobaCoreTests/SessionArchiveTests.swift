import XCTest
@testable import MacMobaCore

/// Export and import. The security-relevant behaviour — that a plain export
/// cannot carry credentials — is the point of most of these.
final class SessionArchiveTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func sampleVault() -> VaultData {
        VaultData(
            sessions: [
                SessionConfig(id: "s1", name: "web", host: "web.example.com", port: 22,
                              username: "deploy", authType: "password", password: "hunter2"),
                SessionConfig(id: "s2", name: "db", host: "db.example.com", port: 22,
                              username: "admin", authType: "keyfile",
                              keyPath: "~/.ssh/id_ed25519", keyData: "-----BEGIN KEY-----",
                              passphrase: "unlock-me"),
                SessionConfig(id: "s3", name: "win", host: "10.0.0.9", port: 3389,
                              username: "Administrator", authType: "password",
                              password: "P@ssw0rd", kind: "rdp"),
            ],
            tunnels: [],
            macros: [MacroConfig(id: "m1", name: "deploy", command: "make deploy")]
        )
    }

    // MARK: - Secrets

    /// The one that matters: an export without secrets must not carry any.
    func testPlainExportCarriesNoCredentials() throws {
        let archive = SessionExport.archive(from: sampleVault(), includeSecrets: false, now: now)
        let json = String(decoding: try SessionExport.plainJSON(archive), as: UTF8.self)

        for secret in ["hunter2", "unlock-me", "P@ssw0rd", "BEGIN KEY"] {
            XCTAssertFalse(json.contains(secret), "\(secret) leaked into a plain export")
        }
        // ...and it is still a useful file.
        XCTAssertTrue(json.contains("web.example.com"))
        XCTAssertTrue(json.contains("deploy"))
        // The key *path* is not a secret, and keeping it is what lets the
        // session work on a machine that already has the key.
        XCTAssertTrue(json.contains("id_ed25519"))
    }

    func testStrippingClearsEveryCredentialField() {
        let session = sampleVault().sessions[1]
        let stripped = SessionExport.stripSecrets(from: session)
        XCTAssertNil(stripped.password)
        XCTAssertNil(stripped.passphrase)
        XCTAssertNil(stripped.keyData)
        XCTAssertEqual(stripped.keyPath, "~/.ssh/id_ed25519")
        XCTAssertEqual(stripped.host, session.host, "non-secret fields must survive")
    }

    func testSecretsSurviveAnEncryptedRoundTrip() throws {
        let archive = SessionExport.archive(from: sampleVault(), includeSecrets: true, now: now)
        let data = try SessionExport.encrypted(archive, password: "correct horse")
        let reopened = try SessionExport.read(data, password: "correct horse")

        XCTAssertTrue(reopened.includesSecrets)
        XCTAssertEqual(reopened.sessions.count, 3)
        XCTAssertEqual(reopened.sessions[0].password, "hunter2")
        XCTAssertEqual(reopened.sessions[1].passphrase, "unlock-me")
    }

    /// The ciphertext must not be readable, which is easy to get wrong by
    /// accidentally writing the archive alongside the envelope.
    func testEncryptedFileRevealsNothing() throws {
        let archive = SessionExport.archive(from: sampleVault(), includeSecrets: true, now: now)
        let data = try SessionExport.encrypted(archive, password: "pw")
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["hunter2", "unlock-me", "P@ssw0rd", "web.example.com", "Administrator"] {
            XCTAssertFalse(text.contains(secret), "\(secret) is readable in the encrypted file")
        }
        XCTAssertTrue(text.contains("session-export"), "should still be identifiable as ours")
    }

    func testWrongPasswordIsRejected() throws {
        let archive = SessionExport.archive(from: sampleVault(), includeSecrets: true, now: now)
        let data = try SessionExport.encrypted(archive, password: "right")
        XCTAssertThrowsError(try SessionExport.read(data, password: "wrong")) { error in
            XCTAssertEqual(error as? SessionArchiveError, .wrongPassword)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let archive = SessionExport.archive(from: sampleVault(), includeSecrets: true, now: now)
        var data = try SessionExport.encrypted(archive, password: "pw")
        // Flip a character inside the base64 ciphertext.
        var text = String(decoding: data, as: UTF8.self)
        if let range = text.range(of: "\"ct\" : \"") {
            let index = text.index(range.upperBound, offsetBy: 4)
            text.replaceSubrange(index...index, with: text[index] == "A" ? "B" : "A")
        }
        data = Data(text.utf8)
        XCTAssertThrowsError(try SessionExport.read(data, password: "pw"),
                             "GCM must reject a modified file")
    }

    /// The UI needs to know whether to ask for a password before it asks.
    func testEncryptionIsDetectableWithoutThePassword() throws {
        let plain = try SessionExport.plainJSON(
            SessionExport.archive(from: sampleVault(), includeSecrets: false, now: now))
        let sealed = try SessionExport.encrypted(
            SessionExport.archive(from: sampleVault(), includeSecrets: true, now: now),
            password: "pw")
        XCTAssertFalse(SessionExport.isEncrypted(plain))
        XCTAssertTrue(SessionExport.isEncrypted(sealed))
    }

    func testRejectsFilesThatAreNotArchives() {
        // Including JSON that decodes cleanly but is not ours: every field is
        // optional, so without a marker these become "valid" empty archives.
        for junk in ["{}", "[]", "not json at all", "{\"hello\":\"world\"}",
                     "{\"version\":1,\"sessions\":[]}"] {
            XCTAssertThrowsError(try SessionExport.read(Data(junk.utf8), password: nil),
                                 "accepted junk: \(junk)")
        }
    }

    func testRejectsAFormatFromTheFuture() throws {
        var archive = SessionExport.archive(from: sampleVault(), includeSecrets: false, now: now)
        archive.version = SessionArchive.currentVersion + 5
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
        XCTAssertThrowsError(try SessionExport.read(data, password: nil)) { error in
            XCTAssertEqual(error as? SessionArchiveError,
                           .tooNew(SessionArchive.currentVersion + 5))
        }
    }

    // MARK: - Import

    func testImportAddsToWhatIsAlreadyThere() {
        let archive = SessionExport.archive(from: sampleVault(), includeSecrets: false, now: now)
        let existing = VaultData(sessions: [
            SessionConfig(id: "local", name: "mine", host: "other.example.com",
                          port: 22, username: "me")
        ])
        let result = SessionImport.merge(archive, into: existing)
        XCTAssertEqual(result.added, 4)   // 3 sessions + 1 macro
        XCTAssertEqual(result.data.sessions.count, 4)
        XCTAssertTrue(result.data.sessions.contains { $0.id == "local" },
                      "an import must never remove what was already configured")
    }

    /// Importing the same file twice must be a no-op, not a duplicate set.
    func testImportingTwiceChangesNothingTheSecondTime() {
        let archive = SessionExport.archive(from: sampleVault(), includeSecrets: false, now: now)
        let once = SessionImport.merge(archive, into: VaultData())
        let twice = SessionImport.merge(archive, into: once.data)
        XCTAssertEqual(twice.added, 0)
        XCTAssertEqual(twice.skipped, 3)
        XCTAssertEqual(twice.data.sessions.count, once.data.sessions.count)
        XCTAssertEqual(twice.data.macros.count, once.data.macros.count)
    }

    /// The same session carried between machines usually arrives with a new id,
    /// so identity has to fall back to what it actually connects to.
    func testDoesNotDuplicateTheSameHostUnderANewID() {
        let existing = VaultData(sessions: [
            SessionConfig(id: "original", name: "web", host: "web.example.com",
                          port: 22, username: "deploy")
        ])
        let incoming = SessionArchive(
            exportedAt: now,
            sessions: [SessionConfig(id: "brand-new-id", name: "web (copy)",
                                     host: "web.example.com", port: 22, username: "deploy")]
        )
        let result = SessionImport.merge(incoming, into: existing)
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.skipped, 1)
    }

    /// Same host, different user or protocol, is a different session.
    func testTreatsADifferentUserOrProtocolAsDistinct() {
        let existing = VaultData(sessions: [
            SessionConfig(id: "a", name: "web", host: "h", port: 22, username: "deploy")
        ])
        let incoming = SessionArchive(exportedAt: now, sessions: [
            SessionConfig(id: "b", name: "web-root", host: "h", port: 22, username: "root"),
            SessionConfig(id: "c", name: "web-telnet", host: "h", port: 22,
                          username: "deploy", kind: "telnet"),
        ])
        let result = SessionImport.merge(incoming, into: existing)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.skipped, 0)
    }

    // MARK: - update mode (ongoing team sync)

    func testUpdateModeRefreshesMatchedSessionButAdditiveDoesNot() {
        let existing = VaultData(sessions: [
            SessionConfig(id: "shared", name: "web", host: "web.example.com",
                          port: 22, username: "deploy")
        ])
        // A teammate moved the host to a new port and renamed it.
        let incoming = SessionArchive(exportedAt: now, sessions: [
            SessionConfig(id: "shared", name: "web (prod)", host: "web.example.com",
                          port: 2222, username: "deploy")
        ], includesSecrets: true)

        // Additive leaves the local one untouched.
        let add = SessionImport.merge(incoming, into: existing, mode: .additive)
        XCTAssertEqual(add.updated, 0)
        XCTAssertEqual(add.skipped, 1)
        XCTAssertEqual(add.data.sessions.first?.port, 22)

        // Update pulls the change in.
        let upd = SessionImport.merge(incoming, into: existing, mode: .update)
        XCTAssertEqual(upd.updated, 1)
        XCTAssertEqual(upd.added, 0)
        XCTAssertEqual(upd.data.sessions.count, 1, "update must not duplicate")
        XCTAssertEqual(upd.data.sessions.first?.port, 2222)
        XCTAssertEqual(upd.data.sessions.first?.name, "web (prod)")
    }

    func testUpdateModeKeepsLocalSecretWhenArchiveHasNone() {
        let existing = VaultData(sessions: [
            SessionConfig(id: "s", name: "db", host: "db", port: 22,
                          username: "admin", password: "localsecret")
        ])
        // Secret-stripped export (the safe default) with an edited port.
        let incoming = SessionArchive(exportedAt: now, sessions: [
            SessionConfig(id: "s", name: "db", host: "db", port: 5432, username: "admin")
        ], includesSecrets: false)

        let upd = SessionImport.merge(incoming, into: existing, mode: .update)
        let s = upd.data.sessions.first
        XCTAssertEqual(s?.port, 5432, "the edit should apply")
        XCTAssertEqual(s?.password, "localsecret", "a stripped export must not blank the saved password")
    }

    func testUpdateModeStillAddsNewAndSkipsTargetOnlyMatches() {
        let existing = VaultData(sessions: [
            SessionConfig(id: "have", name: "a", host: "a", port: 22, username: "u")
        ])
        let incoming = SessionArchive(exportedAt: now, sessions: [
            SessionConfig(id: "have", name: "a2", host: "a", port: 22, username: "u"),  // update
            SessionConfig(id: "new", name: "b", host: "b", port: 22, username: "u"),    // add
            SessionConfig(id: "dup", name: "a-copy", host: "a", port: 22, username: "u"), // same target as "have"
        ], includesSecrets: true)

        let upd = SessionImport.merge(incoming, into: existing, mode: .update)
        XCTAssertEqual(upd.updated, 1)
        XCTAssertEqual(upd.added, 1)
        XCTAssertEqual(upd.skipped, 1)   // the target-duplicate
    }

    func testArchiveFromAnOlderBuildStillDecodes() throws {
        // No `includesSecrets`, no `macros` — a plausible earlier file.
        // Marker present, but missing the fields added later.
        let json = """
        {"macmoba":"session-export","version":1,
         "sessions":[{"id":"x","name":"n","host":"h","port":22,
          "username":"u","authType":"password"}]}
        """
        let archive = try SessionExport.read(Data(json.utf8), password: nil)
        XCTAssertEqual(archive.sessions.count, 1)
        XCTAssertFalse(archive.includesSecrets)
        XCTAssertTrue(archive.macros.isEmpty)
    }
}

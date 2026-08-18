import XCTest

@testable import MacMobaCore

final class SessionDuplicateTests: XCTestCase {
    private func session() -> SessionConfig {
        var config = SessionConfig(
            id: "original", name: "web-server", host: "192.0.2.5", port: 2222,
            username: "root", authType: "keyfile", password: "hunter2",
            keyPath: "~/.ssh/id_ed25519", keyData: nil, passphrase: "phrase",
            group: "Production", proxyJump: "bastion-id", kind: "ssh",
            domain: "CORP", rdpSecurity: "nla", sharedFolders: ["/tmp/share"],
            rdpDisplayMode: "fixed", rdpWidth: 1600, rdpHeight: 900,
            ftpTLS: nil, rdpUseAllDisplays: nil)
        config.rdpAlternateShell = "PSM@token"
        return config
    }

    /// The whole point: change a field or two afterwards, not fill it all in
    /// again.
    func testEverythingButIdAndNameIsKept() {
        let original = session()
        let copy = SessionDuplicate.copy(of: original, existingNames: [original.name])

        XCTAssertEqual(copy.host, original.host)
        XCTAssertEqual(copy.port, original.port)
        XCTAssertEqual(copy.username, original.username)
        XCTAssertEqual(copy.authType, original.authType)
        XCTAssertEqual(copy.password, original.password)
        XCTAssertEqual(copy.keyPath, original.keyPath)
        XCTAssertEqual(copy.passphrase, original.passphrase)
        XCTAssertEqual(copy.group, original.group, "the copy belongs in the same folder")
        XCTAssertEqual(copy.proxyJump, original.proxyJump)
        XCTAssertEqual(copy.sessionKind, original.sessionKind)
        XCTAssertEqual(copy.domain, original.domain)
        XCTAssertEqual(copy.rdpSecurity, original.rdpSecurity)
        XCTAssertEqual(copy.sharedFolders, original.sharedFolders)
        XCTAssertEqual(copy.rdpWidth, original.rdpWidth)
        XCTAssertEqual(copy.rdpHeight, original.rdpHeight)
        XCTAssertEqual(copy.rdpAlternateShell, original.rdpAlternateShell)
    }

    /// Two sessions sharing an id are the same session to the vault, to open
    /// tabs, and to anything using it as a jump host.
    func testTheCopyGetsItsOwnId() {
        let original = session()
        let copy = SessionDuplicate.copy(of: original, existingNames: [])
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertFalse(copy.id.isEmpty)
    }

    func testFirstCopyIsNamedCopy() {
        let copy = SessionDuplicate.copy(of: session(), existingNames: ["web-server"])
        XCTAssertEqual(copy.name, "web-server copy")
    }

    func testSecondCopyIsNumbered() {
        let copy = SessionDuplicate.copy(of: session(),
                                         existingNames: ["web-server", "web-server copy"])
        XCTAssertEqual(copy.name, "web-server copy 2")
    }

    func testNumberingSkipsWhatIsTaken() {
        let copy = SessionDuplicate.copy(
            of: session(),
            existingNames: ["web-server", "web-server copy", "web-server copy 2",
                            "web-server copy 3"])
        XCTAssertEqual(copy.name, "web-server copy 4")
    }

    /// Duplicating a copy must not stack the word.
    func testDuplicatingACopyExtendsTheNumber() {
        var original = session()
        original.name = "web-server copy"
        let copy = SessionDuplicate.copy(of: original,
                                         existingNames: ["web-server", "web-server copy"])
        XCTAssertEqual(copy.name, "web-server copy 2")

        var numbered = session()
        numbered.name = "web-server copy 2"
        let again = SessionDuplicate.copy(
            of: numbered, existingNames: ["web-server copy", "web-server copy 2"])
        XCTAssertEqual(again.name, "web-server copy 3")
    }

    /// "copy" inside a name is not the suffix.
    func testAnUnrelatedCopyWordIsNotStripped() {
        var original = session()
        original.name = "copy machine"
        let copy = SessionDuplicate.copy(of: original, existingNames: ["copy machine"])
        XCTAssertEqual(copy.name, "copy machine copy")
    }

    func testAnEmptyNameStillProducesSomething() {
        var original = session()
        original.name = "   "
        let copy = SessionDuplicate.copy(of: original, existingNames: [])
        XCTAssertEqual(copy.name, "Session copy")
    }

    func testStemStripsOnlyTheSuffix() {
        XCTAssertEqual(SessionDuplicate.stem(of: "web copy"), "web")
        XCTAssertEqual(SessionDuplicate.stem(of: "web copy 7"), "web")
        XCTAssertEqual(SessionDuplicate.stem(of: "web"), "web")
        XCTAssertEqual(SessionDuplicate.stem(of: "copycat"), "copycat")
    }

    /// A duplicate has to survive the vault, since that is where it lands.
    func testTheCopyRoundTripsThroughTheVault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-vault-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let vault = Vault(fileURL: url)
        var data = try vault.create(masterPassword: "hunter2")
        let original = session()
        data.sessions = [original, SessionDuplicate.copy(of: original,
                                                         existingNames: [original.name])]
        try vault.save(data)

        let loaded = try Vault(fileURL: url).unlock(masterPassword: "hunter2")
        XCTAssertEqual(loaded.sessions.count, 2)
        XCTAssertEqual(loaded.sessions[1].name, "web-server copy")
        XCTAssertEqual(loaded.sessions[1].password, "hunter2")
        XCTAssertEqual(loaded.sessions[1].rdpAlternateShell, "PSM@token")
        XCTAssertNotEqual(loaded.sessions[1].id, loaded.sessions[0].id)
    }
}

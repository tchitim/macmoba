import XCTest

@testable import MacMobaCore

/// The promise of shared credentials is that changing one login updates every
/// host that uses it, and that inheritance composes predictably. These pin down
/// the precedence — explicit credential > group default > inline — and the
/// safety fallbacks that stop a session logging in as the wrong (or empty) user.
final class CredentialResolverTests: XCTestCase {
    private func session(_ name: String, group: String? = nil,
                         ref: String? = nil,
                         username: String = "inline-user",
                         password: String? = "inline-pw") -> SessionConfig {
        var s = SessionConfig(id: "sess-\(name)", name: name, host: "h", port: 22,
                              username: username, authType: "password", password: password)
        s.group = group
        s.credentialRef = ref
        return s
    }

    private let cred = CredentialConfig(id: "cred-A", name: "Shared A",
                                        username: "shared-user", authType: "password",
                                        password: "shared-pw")

    // MARK: - inline (default)

    func testNoRefUsesInlineFields() {
        let resolved = CredentialResolver.resolve(session("s"), credentials: [cred],
                                                  groupCredentials: [:])
        XCTAssertEqual(resolved.username, "inline-user")
        XCTAssertEqual(resolved.password, "inline-pw")
    }

    func testEmptyOrCustomRefIsInline() {
        for ref in ["", "custom", "   "] {
            let resolved = CredentialResolver.resolve(session("s", ref: ref),
                                                      credentials: [cred], groupCredentials: [:])
            XCTAssertEqual(resolved.username, "inline-user", "ref=\(ref)")
        }
    }

    // MARK: - explicit credential

    func testExplicitCredentialReplacesLogin() {
        let resolved = CredentialResolver.resolve(session("s", ref: "cred-A"),
                                                  credentials: [cred], groupCredentials: [:])
        XCTAssertEqual(resolved.username, "shared-user")
        XCTAssertEqual(resolved.password, "shared-pw")
        // Everything that is not a login is left alone.
        XCTAssertEqual(resolved.host, "h")
        XCTAssertEqual(resolved.port, 22)
    }

    /// The whole selling point: edit the credential, every referencing session
    /// sees the change without being touched.
    func testEditingTheCredentialUpdatesAllReferencingSessions() {
        var updated = cred
        updated.password = "rotated-pw"
        let a = CredentialResolver.resolve(session("a", ref: "cred-A"),
                                           credentials: [updated], groupCredentials: [:])
        let b = CredentialResolver.resolve(session("b", ref: "cred-A"),
                                           credentials: [updated], groupCredentials: [:])
        XCTAssertEqual(a.password, "rotated-pw")
        XCTAssertEqual(b.password, "rotated-pw")
    }

    /// A reference to a credential that no longer exists must fall back to the
    /// session's own fields, not log in as an empty user.
    func testDeletedCredentialFallsBackToInline() {
        let resolved = CredentialResolver.resolve(session("s", ref: "cred-GONE"),
                                                  credentials: [cred], groupCredentials: [:])
        XCTAssertEqual(resolved.username, "inline-user")
        XCTAssertEqual(CredentialResolver.source(for: session("s", ref: "cred-GONE"),
                                                 credentials: [cred], groupCredentials: [:]),
                       .custom)
    }

    // MARK: - group inheritance

    func testInheritUsesGroupDefault() {
        let s = session("s", group: "Production", ref: CredentialResolver.inherit)
        let resolved = CredentialResolver.resolve(s, credentials: [cred],
                                                  groupCredentials: ["Production": "cred-A"])
        XCTAssertEqual(resolved.username, "shared-user")
        XCTAssertEqual(CredentialResolver.source(for: s, credentials: [cred],
                                                 groupCredentials: ["Production": "cred-A"]),
                       .inheritedFromGroup(credentialID: "cred-A"))
    }

    /// Explicit beats inherited: a session that names a credential ignores its
    /// group's default.
    func testExplicitOverridesGroupDefault() {
        let other = CredentialConfig(id: "cred-B", name: "B", username: "b-user",
                                     password: "b-pw")
        let s = session("s", group: "Production", ref: "cred-B")
        let resolved = CredentialResolver.resolve(s, credentials: [cred, other],
                                                  groupCredentials: ["Production": "cred-A"])
        XCTAssertEqual(resolved.username, "b-user")
    }

    /// Set to inherit but the group has no default: fall back to inline, and
    /// say so, so the editor can show "inherit (nothing set)".
    func testInheritWithNoGroupDefaultIsInline() {
        let s = session("s", group: "Production", ref: CredentialResolver.inherit)
        let resolved = CredentialResolver.resolve(s, credentials: [cred], groupCredentials: [:])
        XCTAssertEqual(resolved.username, "inline-user")
        XCTAssertEqual(CredentialResolver.source(for: s, credentials: [cred],
                                                 groupCredentials: [:]),
                       .inheritedButNone)
    }

    func testInheritWithNoGroupIsInline() {
        let s = session("s", group: nil, ref: CredentialResolver.inherit)
        XCTAssertEqual(CredentialResolver.source(for: s, credentials: [cred],
                                                 groupCredentials: ["Production": "cred-A"]),
                       .inheritedButNone)
    }

    /// Nested folders inherit upward (Royal TSX-style): a session in
    /// "Production/Linux" with no default there uses "Production"'s.
    func testInheritWalksUpTheFolderPath() {
        let s = session("s", group: "Production/Linux", ref: CredentialResolver.inherit)
        let resolved = CredentialResolver.resolve(s, credentials: [cred],
                                                  groupCredentials: ["Production": "cred-A"])
        XCTAssertEqual(resolved.username, "shared-user")
        XCTAssertEqual(CredentialResolver.source(for: s, credentials: [cred],
                                                 groupCredentials: ["Production": "cred-A"]),
                       .inheritedFromGroup(credentialID: "cred-A"))
    }

    /// The nearest ancestor wins: the subfolder's own default beats the parent's.
    func testNearestFolderDefaultWins() {
        let linuxCred = CredentialConfig(id: "cred-L", name: "L", username: "linux-user",
                                         password: "l-pw")
        let s = session("s", group: "Production/Linux", ref: CredentialResolver.inherit)
        let resolved = CredentialResolver.resolve(
            s, credentials: [cred, linuxCred],
            groupCredentials: ["Production": "cred-A", "Production/Linux": "cred-L"])
        XCTAssertEqual(resolved.username, "linux-user")
    }

    /// No default anywhere on the path: inline, reported as such.
    func testInheritPathWithNoDefaultsIsInline() {
        let s = session("s", group: "Production/Linux", ref: CredentialResolver.inherit)
        XCTAssertEqual(CredentialResolver.source(for: s, credentials: [cred],
                                                 groupCredentials: ["Other": "cred-A"]),
                       .inheritedButNone)
    }

    // MARK: - key material and domain

    func testResolvingCarriesKeyMaterialNotJustPassword() {
        let keyCred = CredentialConfig(id: "cred-K", name: "Key", username: "root",
                                       authType: "keytext", password: nil,
                                       keyData: "-----BEGIN-----", passphrase: "pp")
        let resolved = CredentialResolver.resolve(session("s", ref: "cred-K"),
                                                  credentials: [keyCred], groupCredentials: [:])
        XCTAssertEqual(resolved.authType, "keytext")
        XCTAssertEqual(resolved.keyData, "-----BEGIN-----")
        XCTAssertEqual(resolved.passphrase, "pp")
        XCTAssertNil(resolved.password)
    }

    /// A credential with no domain must not blank out a domain the session set
    /// for itself.
    func testCredentialWithoutDomainKeepsSessionDomain() {
        var s = session("s", ref: "cred-A")
        s.domain = "CORP"
        let resolved = CredentialResolver.resolve(s, credentials: [cred], groupCredentials: [:])
        XCTAssertEqual(resolved.domain, "CORP")
    }

    func testCredentialDomainWins() {
        var domained = cred
        domained.domain = "AD"
        var s = session("s", ref: "cred-A")
        s.domain = "CORP"
        let resolved = CredentialResolver.resolve(s, credentials: [domained], groupCredentials: [:])
        XCTAssertEqual(resolved.domain, "AD")
    }

    // MARK: - back-compat decoding

    func testVaultWithoutCredentialsKeysStillDecodes() throws {
        let json = #"{"sessions":[],"tunnels":[],"macros":[]}"#
        let data = try JSONDecoder().decode(VaultData.self, from: Data(json.utf8))
        XCTAssertEqual(data.credentials, [])
        XCTAssertEqual(data.groupCredentials, [:])
    }

    /// A vault written before folders existed must still open — and come back
    /// with no folders rather than failing to decode.
    func testVaultWithoutFoldersKeyStillDecodes() throws {
        let json = #"{"sessions":[],"tunnels":[],"macros":[]}"#
        let data = try JSONDecoder().decode(VaultData.self, from: Data(json.utf8))
        XCTAssertEqual(data.folders, [])
    }

    func testFoldersRoundTripThroughJSON() throws {
        let vault = VaultData(folders: ["Production", "Production/Linux"])
        let decoded = try JSONDecoder().decode(VaultData.self,
                                               from: JSONEncoder().encode(vault))
        XCTAssertEqual(decoded.folders, ["Production", "Production/Linux"])
    }

    func testCredentialsRoundTripThroughJSON() throws {
        let vault = VaultData(sessions: [session("s", ref: "cred-A")],
                              credentials: [cred],
                              groupCredentials: ["Production": "cred-A"])
        let encoded = try JSONEncoder().encode(vault)
        let decoded = try JSONDecoder().decode(VaultData.self, from: encoded)
        XCTAssertEqual(decoded, vault)
    }
}

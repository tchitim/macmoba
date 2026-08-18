import XCTest
import Crypto
@testable import MacMobaCore

/// The strongest proof a generated key is correct is that OpenSSH itself
/// accepts it: these write the key to disk and run the system `ssh-keygen` to
/// re-derive the public key and fingerprint, then check they match what we
/// produced. Also a pure round-trip back through our own parser.
final class SSHKeyGeneratorTests: XCTestCase {

    private let keygen = "/usr/bin/ssh-keygen"

    // MARK: - our parser accepts what we generate

    func testEveryTypeReparsesUnencrypted() throws {
        for type in SSHKeyType.allCases {
            let key = SSHKeyGenerator.generate(type: type, comment: "me@mac")
            XCTAssertTrue(key.privateKeyPEM.contains("BEGIN OPENSSH PRIVATE KEY"))
            XCTAssertTrue(key.publicKeyLine.hasPrefix(type.keyTypeName), "wrong pub prefix for \(type)")
            XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
            // Must parse without throwing.
            _ = try OpenSSHKeyParser.parse(pem: key.privateKeyPEM, passphrase: nil)
        }
    }

    func testEncryptedKeyReparsesWithPassphraseAndFailsWithout() throws {
        let key = SSHKeyGenerator.generate(type: .ed25519, comment: "e@mac", passphrase: "s3cret")
        _ = try OpenSSHKeyParser.parse(pem: key.privateKeyPEM, passphrase: "s3cret")
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem: key.privateKeyPEM, passphrase: "wrong"))
    }

    // MARK: - fingerprint is computed the ssh-keygen way

    func testFingerprintMatchesManualSHA256OfBlob() {
        let key = SSHKeyGenerator.generate(type: .ed25519)
        // Recompute from the public key line's blob and compare.
        let blob = Data(base64Encoded: key.publicKeyLine.split(separator: " ")[1].description)!
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(key.fingerprint, "SHA256:\(digest)")
    }

    // MARK: - ground truth: OpenSSH's own ssh-keygen agrees

    func testSSHKeygenDerivesTheSamePublicKey() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: keygen), "no ssh-keygen")
        for type in SSHKeyType.allCases {
            let key = SSHKeyGenerator.generate(type: type, comment: "gen@test")
            let file = try writeTempKey(key.privateKeyPEM)
            defer { try? FileManager.default.removeItem(atPath: file) }

            // `ssh-keygen -y` re-derives the public key from the private one.
            let out = try run(keygen, ["-y", "-f", file])
            let derived = out.split(separator: " ")
            let ours = key.publicKeyLine.split(separator: " ")
            XCTAssertEqual(derived[0], ours[0], "\(type): key type differs")
            XCTAssertEqual(derived[1], ours[1], "\(type): ssh-keygen derived a different public key")
        }
    }

    func testSSHKeygenReportsTheSameFingerprint() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: keygen), "no ssh-keygen")
        let key = SSHKeyGenerator.generate(type: .ecdsaP256, comment: "fp@test")
        let file = try writeTempKey(key.privateKeyPEM)
        defer { try? FileManager.default.removeItem(atPath: file) }

        // `256 SHA256:xxxx comment (ECDSA)` — the second field is the fingerprint.
        let out = try run(keygen, ["-l", "-f", file])
        let fp = out.split(separator: " ").first { $0.hasPrefix("SHA256:") }
        XCTAssertEqual(fp.map(String.init), key.fingerprint)
    }

    func testSSHKeygenAcceptsAnEncryptedKey() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: keygen), "no ssh-keygen")
        let key = SSHKeyGenerator.generate(type: .ed25519, comment: "enc@test", passphrase: "pw-123")
        let file = try writeTempKey(key.privateKeyPEM)
        defer { try? FileManager.default.removeItem(atPath: file) }

        // -P gives the passphrase non-interactively; success means our bcrypt +
        // aes256-ctr encryption is exactly what OpenSSH expects.
        let out = try run(keygen, ["-y", "-P", "pw-123", "-f", file])
        XCTAssertEqual(out.split(separator: " ")[1], key.publicKeyLine.split(separator: " ")[1])
    }

    // MARK: - helpers

    private func writeTempKey(_ pem: String) throws -> String {
        let path = NSTemporaryDirectory() + "macmoba-key-\(UUID().uuidString)"
        try pem.write(toFile: path, atomically: true, encoding: .utf8)
        // ssh-keygen refuses/warns on world-readable private keys.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    private func run(_ tool: String, _ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

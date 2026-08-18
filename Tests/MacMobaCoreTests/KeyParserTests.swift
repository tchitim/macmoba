// Key parser tests against real `ssh-keygen` output, including
// passphrase-encrypted keys (validates the bcrypt_pbkdf port end-to-end:
// decrypted private key must reproduce the .pub file's public key).

import Foundation
import XCTest

@testable import MacMobaCore

final class KeyParserTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmoba-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func keygen(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func makeKey(type: String, bits: Int? = nil, passphrase: String,
                         name: String) throws -> (pem: String, pub: String) {
        let path = dir.appendingPathComponent(name).path
        var args = ["-t", type, "-N", passphrase, "-f", path, "-q", "-C", "test"]
        if let bits { args += ["-b", "\(bits)"] }
        guard try keygen(args) == 0 else {
            throw XCTSkip("ssh-keygen could not generate \(type) key")
        }
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        let pub = try String(contentsOfFile: path + ".pub", encoding: .utf8)
        return (pem, pub)
    }

    /// "type base64" prefix of an authorized_keys line.
    private func keyBlob(_ pubLine: String) -> String {
        pubLine.split(separator: " ").prefix(2).joined(separator: " ")
    }

    private func assertParsesAndMatches(pem: String, pub: String, passphrase: String?,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let key = try OpenSSHKeyParser.parse(pem: pem, passphrase: passphrase)
        let derived = String(openSSHPublicKey: key.publicKey)
        XCTAssertEqual(derived, keyBlob(pub), file: file, line: line)
    }

    // MARK: - Unencrypted

    func testUnencryptedCurves() throws {
        for (type, bits, name) in [("ed25519", nil, "ed"), ("ecdsa", 256, "e256"),
                                   ("ecdsa", 384, "e384"), ("ecdsa", 521, "e521")] as [(String, Int?, String)] {
            let (pem, pub) = try makeKey(type: type, bits: bits, passphrase: "", name: name)
            try assertParsesAndMatches(pem: pem, pub: pub, passphrase: nil)
        }
    }

    // MARK: - Encrypted

    func testEncryptedEd25519() throws {
        let (pem, pub) = try makeKey(type: "ed25519", passphrase: "test-pass-123", name: "enc-ed")
        try assertParsesAndMatches(pem: pem, pub: pub, passphrase: "test-pass-123")
    }

    func testEncryptedEcdsa() throws {
        let (pem, pub) = try makeKey(type: "ecdsa", bits: 256, passphrase: "秘密pass!", name: "enc-ec")
        try assertParsesAndMatches(pem: pem, pub: pub, passphrase: "秘密pass!")
    }

    func testWrongPassphraseRejected() throws {
        let (pem, _) = try makeKey(type: "ed25519", passphrase: "correct", name: "wrongpw")
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem: pem, passphrase: "incorrect")) { error in
            XCTAssertTrue("\(error)".contains("wrong passphrase"), "unexpected: \(error)")
        }
    }

    func testMissingPassphraseExplained() throws {
        let (pem, _) = try makeKey(type: "ed25519", passphrase: "correct", name: "nopw")
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem: pem, passphrase: nil)) { error in
            XCTAssertTrue("\(error)".contains("passphrase-protected"), "unexpected: \(error)")
        }
    }

    func testRSAGivesClearError() throws {
        let (pem, _) = try makeKey(type: "rsa", bits: 2048, passphrase: "", name: "rsa")
        XCTAssertThrowsError(try OpenSSHKeyParser.parse(pem: pem, passphrase: nil)) { error in
            XCTAssertTrue("\(error)".contains("RSA"), "unexpected: \(error)")
        }
    }
}

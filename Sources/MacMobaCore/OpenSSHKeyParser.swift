// OpenSSH private key parser ("-----BEGIN OPENSSH PRIVATE KEY-----",
// openssh-key-v1 format).
// Supports: ed25519, ECDSA P-256/384/521; unencrypted or passphrase-encrypted
// (bcrypt KDF + aes128/192/256-ctr or aes256-cbc — everything ssh-keygen
// emits by default). RSA is not supported by SwiftNIO SSH itself.

import Crypto
import CryptoSwift
import Foundation
import NIOSSH

enum OpenSSHKeyParser {
    private static let magic = "openssh-key-v1\0"

    static func parse(pem: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let lines = pem.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.contains("BEGIN OPENSSH PRIVATE KEY") == true else {
            throw SSHError.keyUnsupported("only OpenSSH-format keys are supported (found: \(lines.first ?? "empty"))")
        }
        let body = lines.dropFirst().dropLast().joined()
        guard let blob = Data(base64Encoded: body) else {
            throw SSHError.keyUnsupported("invalid base64 in key file")
        }
        var reader = Reader(blob)
        guard let magicBytes = reader.take(magic.utf8.count),
              String(decoding: magicBytes, as: UTF8.self) == magic else {
            throw SSHError.keyUnsupported("bad openssh-key-v1 magic")
        }
        guard let cipher = reader.string(), let kdf = reader.string(),
              let kdfOptions = reader.lengthPrefixed(),
              let nkeys = reader.uint32() else {
            throw SSHError.keyUnsupported("truncated key header")
        }
        guard nkeys == 1 else { throw SSHError.keyUnsupported("multi-key files not supported") }
        guard reader.lengthPrefixed() != nil, // public key blob
              let privBlock = reader.lengthPrefixed() else {
            throw SSHError.keyUnsupported("truncated key body")
        }

        let plaintext: Data
        if cipher == "none" && kdf == "none" {
            plaintext = privBlock
        } else {
            plaintext = try decrypt(privBlock, cipher: cipher, kdf: kdf,
                                    kdfOptions: kdfOptions, passphrase: passphrase)
        }

        var priv = Reader(plaintext)
        guard let check1 = priv.uint32(), let check2 = priv.uint32() else {
            throw SSHError.keyUnsupported("truncated private block")
        }
        guard check1 == check2 else {
            throw SSHError.keyUnsupported("wrong passphrase")
        }
        guard let keyType = priv.string() else {
            throw SSHError.keyUnsupported("truncated private block")
        }
        switch keyType {
        case "ssh-ed25519":
            guard priv.lengthPrefixed() != nil, // public
                  let sk = priv.lengthPrefixed(), sk.count == 64 else {
                throw SSHError.keyUnsupported("bad ed25519 key body")
            }
            let seed = sk.prefix(32)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return NIOSSHPrivateKey(ed25519Key: key)
        case "ecdsa-sha2-nistp256":
            let raw = try ecdsaScalar(&priv, size: 32)
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: raw))
        case "ecdsa-sha2-nistp384":
            let raw = try ecdsaScalar(&priv, size: 48)
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: raw))
        case "ecdsa-sha2-nistp521":
            let raw = try ecdsaScalar(&priv, size: 66)
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: raw))
        case "ssh-rsa":
            throw SSHError.keyUnsupported(
                "RSA keys are not supported by SwiftNIO SSH — generate an ed25519 key instead: ssh-keygen -t ed25519")
        default:
            throw SSHError.keyUnsupported("key type \(keyType) not supported (ed25519 / ecdsa-p256/384/521)")
        }
    }

    /// ECDSA private scalar, mpint-style: may carry a leading zero byte, and
    /// P-521 scalars can legitimately be shorter than the field size.
    private static func ecdsaScalar(_ priv: inout Reader, size: Int) throws -> Data {
        guard priv.string() != nil, // curve name
              priv.lengthPrefixed() != nil, // public point
              let scalar = priv.lengthPrefixed() else {
            throw SSHError.keyUnsupported("bad ecdsa key body")
        }
        var raw = scalar
        while raw.count > size && raw.first == 0 { raw = raw.dropFirst() }
        if raw.count < size {
            raw = Data(repeating: 0, count: size - raw.count) + raw
        }
        return raw
    }

    // MARK: - Encrypted keys

    private static func decrypt(
        _ ciphertext: Data,
        cipher: String,
        kdf: String,
        kdfOptions: Data,
        passphrase: String?
    ) throws -> Data {
        guard kdf == "bcrypt" else {
            throw SSHError.keyUnsupported("unsupported KDF \(kdf)")
        }
        guard let passphrase, !passphrase.isEmpty else {
            throw SSHError.keyUnsupported("key is passphrase-protected — enter the passphrase")
        }

        let (keySize, ivSize, mode): (Int, Int, String)
        switch cipher {
        case "aes256-ctr": (keySize, ivSize, mode) = (32, 16, "ctr")
        case "aes192-ctr": (keySize, ivSize, mode) = (24, 16, "ctr")
        case "aes128-ctr": (keySize, ivSize, mode) = (16, 16, "ctr")
        case "aes256-cbc": (keySize, ivSize, mode) = (32, 16, "cbc")
        case "aes128-cbc": (keySize, ivSize, mode) = (16, 16, "cbc")
        default:
            throw SSHError.keyUnsupported("unsupported cipher \(cipher)")
        }

        var opts = Reader(kdfOptions)
        guard let salt = opts.lengthPrefixed(), let rounds = opts.uint32() else {
            throw SSHError.keyUnsupported("bad bcrypt KDF options")
        }
        let derived = BcryptPBKDF.derive(
            password: Array(passphrase.utf8),
            salt: Array(salt),
            rounds: Int(rounds),
            keyLength: keySize + ivSize
        )
        let key = Array(derived[0..<keySize])
        let iv = Array(derived[keySize..<(keySize + ivSize)])

        do {
            let blockMode: BlockMode = mode == "ctr" ? CTR(iv: iv) : CBC(iv: iv)
            let aes = try AES(key: key, blockMode: blockMode, padding: .noPadding)
            return Data(try aes.decrypt(Array(ciphertext)))
        } catch {
            throw SSHError.keyUnsupported("key decryption failed: \(error)")
        }
    }

    private struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = Data(data) // rebase indices
            self.offset = 0
        }

        mutating func take(_ n: Int) -> Data? {
            guard offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: offset..<(offset + n))
        }

        mutating func uint32() -> UInt32? {
            guard let b = take(4) else { return nil }
            return b.reduce(0) { ($0 << 8) | UInt32($1) }
        }

        mutating func lengthPrefixed() -> Data? {
            guard let len = uint32() else { return nil }
            return take(Int(len))
        }

        mutating func string() -> String? {
            guard let d = lengthPrefixed() else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
    }
}

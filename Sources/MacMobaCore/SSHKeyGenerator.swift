// Generating SSH keypairs, the MobaKeyGen / ssh-keygen job.
//
// The only key types worth emitting are the ones this app (and SwiftNIO SSH)
// can actually use: ed25519 and ECDSA P-256/384/521. RSA is deliberately not
// offered — NIOSSH cannot use it, so producing one would be a trap.
//
// The output is the real OpenSSH format ("-----BEGIN OPENSSH PRIVATE KEY-----",
// openssh-key-v1), byte-for-byte what `ssh-keygen` writes, so a generated key
// works with any SSH server and re-parses through OpenSSHKeyParser. Passphrase
// protection uses the same bcrypt-KDF + aes256-ctr scheme ssh-keygen uses, via
// the BcryptPBKDF already here for reading such keys.

import Crypto
import CryptoSwift
import Foundation

public enum SSHKeyType: String, CaseIterable, Sendable, Identifiable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA (P-256)"
        case .ecdsaP384: return "ECDSA (P-384)"
        case .ecdsaP521: return "ECDSA (P-521)"
        }
    }

    /// The SSH wire name for this key type.
    var keyTypeName: String {
        switch self {
        case .ed25519: return "ssh-ed25519"
        case .ecdsaP256: return "ecdsa-sha2-nistp256"
        case .ecdsaP384: return "ecdsa-sha2-nistp384"
        case .ecdsaP521: return "ecdsa-sha2-nistp521"
        }
    }

    var curveName: String? {
        switch self {
        case .ed25519: return nil
        case .ecdsaP256: return "nistp256"
        case .ecdsaP384: return "nistp384"
        case .ecdsaP521: return "nistp521"
        }
    }
}

public struct GeneratedKey: Equatable, Sendable {
    /// The private key in OpenSSH PEM form — what goes in `~/.ssh/id_...`.
    public let privateKeyPEM: String
    /// The one-line public key — what goes in `authorized_keys` / `.pub`.
    public let publicKeyLine: String
    /// `SHA256:...`, matching `ssh-keygen -lf`.
    public let fingerprint: String
}

public enum SSHKeyGenerator {
    /// Generate a keypair of `type`. `comment` is embedded the way ssh-keygen
    /// embeds user@host; a non-empty `passphrase` encrypts the private key.
    public static func generate(type: SSHKeyType, comment: String = "",
                                passphrase: String? = nil) -> GeneratedKey {
        let (publicBlob, privateEntry) = keyMaterial(for: type)

        let pem = privateKeyPEM(publicBlob: publicBlob, privateEntry: privateEntry,
                                comment: comment, passphrase: passphrase)
        let pubLine = publicKeyLine(type: type, publicBlob: publicBlob, comment: comment)
        let fp = fingerprint(publicBlob: publicBlob)
        return GeneratedKey(privateKeyPEM: pem, publicKeyLine: pubLine, fingerprint: fp)
    }

    // MARK: - key material

    /// Returns (public key blob, private key entry) for a fresh key of `type`.
    /// The private entry is the type-specific part that sits inside the private
    /// section, after the two checkints and before the comment.
    private static func keyMaterial(for type: SSHKeyType) -> (publicBlob: Data, privateEntry: Data) {
        switch type {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            let pub = key.publicKey.rawRepresentation          // 32 bytes
            let seed = key.rawRepresentation                    // 32 bytes
            var pubBlob = Writer()
            pubBlob.putString(type.keyTypeName)
            pubBlob.putData(pub)
            var entry = Writer()
            entry.putString(type.keyTypeName)
            entry.putData(pub)
            entry.putData(seed + pub)                           // 64-byte private
            return (pubBlob.data, entry.data)

        case .ecdsaP256:
            let key = P256.Signing.PrivateKey()
            return ecdsaMaterial(type: type, q: key.publicKey.x963Representation,
                                 d: key.rawRepresentation)
        case .ecdsaP384:
            let key = P384.Signing.PrivateKey()
            return ecdsaMaterial(type: type, q: key.publicKey.x963Representation,
                                 d: key.rawRepresentation)
        case .ecdsaP521:
            let key = P521.Signing.PrivateKey()
            return ecdsaMaterial(type: type, q: key.publicKey.x963Representation,
                                 d: key.rawRepresentation)
        }
    }

    private static func ecdsaMaterial(type: SSHKeyType, q: Data, d: Data)
        -> (publicBlob: Data, privateEntry: Data) {
        let curve = type.curveName!
        var pubBlob = Writer()
        pubBlob.putString(type.keyTypeName)
        pubBlob.putString(curve)
        pubBlob.putData(q)                                     // uncompressed point 0x04||X||Y
        var entry = Writer()
        entry.putString(type.keyTypeName)
        entry.putString(curve)
        entry.putData(q)
        entry.putData(mpint(d))                                // scalar as mpint
        return (pubBlob.data, entry.data)
    }

    /// Big-endian scalar with a leading 0x00 when the top bit is set, so it is
    /// never read back as negative — the mpint convention.
    private static func mpint(_ scalar: Data) -> Data {
        var bytes = Array(scalar)
        while bytes.first == 0 { bytes.removeFirst() }         // no needless leading zeros
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        if bytes.isEmpty { bytes = [0] }
        return Data(bytes)
    }

    // MARK: - serialisation

    private static func privateKeyPEM(publicBlob: Data, privateEntry: Data,
                                      comment: String, passphrase: String?) -> String {
        // The private section: two matching checkints, the key entry, comment,
        // then padding up to the cipher block size.
        var section = Writer()
        let check = UInt32.random(in: .min ... .max)
        section.putUInt32(check)
        section.putUInt32(check)
        section.append(privateEntry)
        section.putString(comment)

        let encrypt = !(passphrase?.isEmpty ?? true)
        let blockSize = encrypt ? 16 : 8
        pad(&section, toMultipleOf: blockSize)

        let cipher: String, kdf: String, kdfOptions: Data, body: Data
        if encrypt, let passphrase {
            let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
            let rounds: UInt32 = 16
            var opts = Writer()
            opts.putData(salt)
            opts.putUInt32(rounds)
            let derived = BcryptPBKDF.derive(password: Array(passphrase.utf8),
                                             salt: Array(salt), rounds: Int(rounds),
                                             keyLength: 32 + 16)
            let key = Array(derived[0..<32])
            let iv = Array(derived[32..<48])
            // CryptoSwift AES-CTR; noPadding because we already block-aligned.
            let ct = (try? AES(key: key, blockMode: CTR(iv: iv), padding: .noPadding)
                .encrypt(Array(section.data))) ?? []
            cipher = "aes256-ctr"; kdf = "bcrypt"; kdfOptions = opts.data; body = Data(ct)
        } else {
            cipher = "none"; kdf = "none"; kdfOptions = Data(); body = section.data
        }

        var blob = Writer()
        blob.append(Data(magic.utf8))
        blob.putString(cipher)
        blob.putString(kdf)
        blob.putData(kdfOptions)
        blob.putUInt32(1)                                      // one key
        blob.putData(publicBlob)
        blob.putData(body)

        let b64 = blob.data.base64EncodedString()
        let wrapped = stride(from: 0, to: b64.count, by: 70).map { start -> String in
            let s = b64.index(b64.startIndex, offsetBy: start)
            let e = b64.index(s, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            return String(b64[s..<e])
        }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + wrapped
                + ["-----END OPENSSH PRIVATE KEY-----", ""]).joined(separator: "\n")
    }

    private static func publicKeyLine(type: SSHKeyType, publicBlob: Data, comment: String) -> String {
        let b64 = publicBlob.base64EncodedString()
        let base = "\(type.keyTypeName) \(b64)"
        return comment.isEmpty ? base : "\(base) \(comment)"
    }

    private static func fingerprint(publicBlob: Data) -> String {
        let digest = SHA256.hash(data: publicBlob)
        // ssh-keygen prints base64 without the trailing '=' padding.
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    private static func pad(_ w: inout Writer, toMultipleOf block: Int) {
        let remainder = w.data.count % block
        guard remainder != 0 else { return }
        for i in 1...(block - remainder) { w.appendByte(UInt8(i)) }
    }

    private static let magic = "openssh-key-v1\0"
}

/// Minimal SSH wire-format writer: big-endian uint32 and length-prefixed strings.
private struct Writer {
    private(set) var data = Data()

    mutating func putUInt32(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    mutating func putData(_ d: Data) {
        putUInt32(UInt32(d.count))
        data.append(d)
    }

    mutating func putString(_ s: String) { putData(Data(s.utf8)) }
    mutating func append(_ d: Data) { data.append(d) }
    mutating func appendByte(_ b: UInt8) { data.append(b) }
}

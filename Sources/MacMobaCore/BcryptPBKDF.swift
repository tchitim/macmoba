// bcrypt_pbkdf — the KDF OpenSSH uses for passphrase-encrypted
// openssh-key-v1 files. Ported from OpenBSD's blf.c / bcrypt_pbkdf.c.
// Verified against real `ssh-keygen` output in the test suite.

import Crypto
import Foundation

struct EksBlowfish {
    private var P: [UInt32]
    private var S: [[UInt32]]

    init() {
        P = BlowfishTables.initialP
        S = BlowfishTables.initialS
    }

    /// Big-endian word from the byte stream, cycling at the end (OpenBSD
    /// Blowfish_stream2word).
    private static func stream2word(_ data: [UInt8], _ position: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            word = (word << 8) | UInt32(data[position])
            position = (position + 1) % data.count
        }
        return word
    }

    private func f(_ x: UInt32) -> UInt32 {
        let a = S[0][Int(x >> 24)]
        let b = S[1][Int((x >> 16) & 0xff)]
        let c = S[2][Int((x >> 8) & 0xff)]
        let d = S[3][Int(x & 0xff)]
        return ((a &+ b) ^ c) &+ d
    }

    mutating func expandstate(data: [UInt8], key: [UInt8]) {
        var j = 0
        for i in 0..<18 {
            P[i] ^= Self.stream2word(key, &j)
        }
        j = 0
        var datal: UInt32 = 0
        var datar: UInt32 = 0
        var i = 0
        while i < 18 {
            datal ^= Self.stream2word(data, &j)
            datar ^= Self.stream2word(data, &j)
            encrypt(&datal, &datar)
            P[i] = datal
            P[i + 1] = datar
            i += 2
        }
        for box in 0..<4 {
            var k = 0
            while k < 256 {
                datal ^= Self.stream2word(data, &j)
                datar ^= Self.stream2word(data, &j)
                encrypt(&datal, &datar)
                S[box][k] = datal
                S[box][k + 1] = datar
                k += 2
            }
        }
    }

    mutating func expand0state(key: [UInt8]) {
        var j = 0
        for i in 0..<18 {
            P[i] ^= Self.stream2word(key, &j)
        }
        var datal: UInt32 = 0
        var datar: UInt32 = 0
        var i = 0
        while i < 18 {
            encrypt(&datal, &datar)
            P[i] = datal
            P[i + 1] = datar
            i += 2
        }
        for box in 0..<4 {
            var k = 0
            while k < 256 {
                encrypt(&datal, &datar)
                S[box][k] = datal
                S[box][k + 1] = datar
                k += 2
            }
        }
    }

    /// One Blowfish block encryption (OpenBSD Blowfish_encipher).
    func encrypt(_ xl: inout UInt32, _ xr: inout UInt32) {
        var Xl = xl ^ P[0]
        var Xr = xr
        var i = 1
        while i <= 15 {
            Xr = (Xr ^ f(Xl)) ^ P[i]
            i += 1
            Xl = (Xl ^ f(Xr)) ^ P[i]
            i += 1
        }
        xl = Xr ^ P[17]
        xr = Xl
    }
}

enum BcryptPBKDF {
    private static let magicString = Array("OxychromaticBlowfishSwatDynamite".utf8)

    /// OpenBSD bcrypt_hash: 32-byte output from two SHA-512 digests.
    static func bcryptHash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        var state = EksBlowfish()
        state.expandstate(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expand0state(key: sha2salt)
            state.expand0state(key: sha2pass)
        }

        // cdata = magic string as 8 big-endian words
        var cdata = [UInt32](repeating: 0, count: 8)
        var j = 0
        for i in 0..<8 {
            var word: UInt32 = 0
            for _ in 0..<4 {
                word = (word << 8) | UInt32(magicString[j])
                j = (j + 1) % magicString.count
            }
            cdata[i] = word
        }
        for _ in 0..<64 {
            var i = 0
            while i < 8 {
                var l = cdata[i]
                var r = cdata[i + 1]
                state.encrypt(&l, &r)
                cdata[i] = l
                cdata[i + 1] = r
                i += 2
            }
        }
        // output little-endian (bcrypt quirk)
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in cdata {
            out.append(UInt8(word & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 24) & 0xff))
        }
        return out
    }

    /// bcrypt_pbkdf(password, salt, rounds) -> keyLength bytes.
    static func derive(password: [UInt8], salt: [UInt8], rounds: Int, keyLength: Int) -> [UInt8] {
        precondition(rounds >= 1 && keyLength > 0 && keyLength <= 1024)
        let sha2pass = [UInt8](SHA512.hash(data: Data(password)))
        var key = [UInt8](repeating: 0, count: keyLength)

        let stride = (keyLength + 32 - 1) / 32
        let amt = (keyLength + stride - 1) / stride
        var remaining = keyLength
        var count: UInt32 = 1
        while remaining > 0 {
            var countSalt = salt
            countSalt.append(UInt8((count >> 24) & 0xff))
            countSalt.append(UInt8((count >> 16) & 0xff))
            countSalt.append(UInt8((count >> 8) & 0xff))
            countSalt.append(UInt8(count & 0xff))

            var sha2salt = [UInt8](SHA512.hash(data: Data(countSalt)))
            var tmpout = bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
            var out = tmpout
            for _ in 1..<rounds {
                sha2salt = [UInt8](SHA512.hash(data: Data(tmpout)))
                tmpout = bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
                for i in 0..<out.count { out[i] ^= tmpout[i] }
            }

            let use = min(amt, remaining)
            var filled = 0
            for i in 0..<use {
                let dest = i * stride + Int(count - 1)
                guard dest < keyLength else { break }
                key[dest] = out[i]
                filled += 1
            }
            remaining -= filled
            count += 1
        }
        return key
    }
}

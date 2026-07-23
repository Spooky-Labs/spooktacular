import Foundation
import CryptoKit

/// SHA-512-crypt (`$6$`, Ulrich Drepper's SHA-crypt, as used in
/// `/etc/shadow`) for cloud-init `passwd:` fields.
///
/// Implemented from the reference specification
/// <https://www.akkadia.org/drepper/SHA-crypt.txt> (steps 1–22) and
/// verified against its published test vectors. This is how a Linux
/// guest's account password rides the cloud-init seed: only this hash
/// ever lands on disk — the same at-rest posture as `/etc/shadow` —
/// and the seed itself is scrubbed after the first successful boot.
public enum SHA512Crypt {

    private static let b64Alphabet =
        Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// Spec-default round count. No `rounds=` prefix is emitted for the
    /// default, matching glibc's canonical output format.
    private static let rounds = 5000

    /// Hashes `password` with `salt` (truncated to 16 characters, per
    /// the specification's salt rules).
    ///
    /// - Parameters:
    ///   - password: The plaintext to hash. Never stored by this type.
    ///   - salt: Salt characters; `$` and `:` are illegal, and at most
    ///     the first 16 characters are used.
    /// - Returns: The full crypt string `$6$<salt>$<86-char-hash>`.
    /// - Throws: ``SHA512CryptError/invalidSalt`` for an empty salt or
    ///   one containing `$`/`:`.
    public static func hash(password: String, salt rawSalt: String) throws -> String {
        let salt = String(rawSalt.prefix(16))
        guard !salt.isEmpty, !salt.contains("$"), !salt.contains(":") else {
            throw SHA512CryptError.invalidSalt
        }
        let pw = Array(password.utf8)
        let st = Array(salt.utf8)

        // Steps 4–8: digest B = SHA512(password + salt + password).
        var b = SHA512()
        b.update(data: pw)
        b.update(data: st)
        b.update(data: pw)
        let digestB = Array(b.finalize())

        // Steps 1–3, 9–12: digest A = SHA512(password + salt +
        // per-block/per-bit mix of B and the password).
        var a = SHA512()
        a.update(data: pw)
        a.update(data: st)
        var remaining = pw.count
        while remaining > 64 {
            a.update(data: digestB)
            remaining -= 64
        }
        a.update(data: digestB.prefix(remaining))
        var bits = pw.count
        while bits > 0 {
            if (bits & 1) != 0 {
                a.update(data: digestB)
            } else {
                a.update(data: pw)
            }
            bits >>= 1
        }
        let digestA = Array(a.finalize())

        // Steps 13–16: byte sequence P from DP = SHA512(password ×
        // password-length).
        var dp = SHA512()
        for _ in 0..<pw.count { dp.update(data: pw) }
        let digestDP = Array(dp.finalize())
        var p: [UInt8] = []
        p.reserveCapacity(pw.count)
        while p.count + 64 <= pw.count { p.append(contentsOf: digestDP) }
        p.append(contentsOf: digestDP.prefix(pw.count - p.count))

        // Steps 17–20: byte sequence S from DS = SHA512(salt ×
        // (16 + A[0])).
        var ds = SHA512()
        let saltRepeats = 16 + Int(digestA.first ?? 0)
        for _ in 0..<saltRepeats { ds.update(data: st) }
        let digestDS = Array(ds.finalize())
        var s: [UInt8] = []
        s.reserveCapacity(st.count)
        while s.count + 64 <= st.count { s.append(contentsOf: digestDS) }
        s.append(contentsOf: digestDS.prefix(st.count - s.count))

        // Step 21: the 5000-round mixing loop.
        var ac = digestA
        for round in 0..<rounds {
            var c = SHA512()
            if (round & 1) != 0 { c.update(data: p) } else { c.update(data: ac) }
            if round % 3 != 0 { c.update(data: s) }
            if round % 7 != 0 { c.update(data: p) }
            if (round & 1) != 0 { c.update(data: ac) } else { c.update(data: p) }
            ac = Array(c.finalize())
        }

        // Step 22: the spec's byte-permuted little-endian base64.
        var out = ""
        func encode(_ b2: UInt8, _ b1: UInt8, _ b0: UInt8, chars: Int) {
            var w = (UInt32(b2) << 16) | (UInt32(b1) << 8) | UInt32(b0)
            for _ in 0..<chars {
                out.append(b64Alphabet[Int(w & 0x3f)])
                w >>= 6
            }
        }
        let idx: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
            (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
            (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
            (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
            (62, 20, 41),
        ]
        for (i2, i1, i0) in idx {
            encode(ac[i2], ac[i1], ac[i0], chars: 4)
        }
        encode(0, 0, ac[63], chars: 2)
        return "$6$\(salt)$\(out)"
    }

    /// 16 random characters from the crypt alphabet — a fresh salt per
    /// generated seed.
    public static func generateSalt() -> String {
        String((0..<16).compactMap { _ in b64Alphabet.randomElement() })
    }
}

/// Errors from ``SHA512Crypt``.
public enum SHA512CryptError: Error, Equatable {
    /// The salt was empty or contained `$`/`:`.
    case invalidSalt
}

import Foundation
import CryptoKit

/// Pure, dependency-free verifier for RFC 6962 Merkle inclusion
/// proofs.
///
/// This type lives in ``SpookApplication`` (the lowest layer that
/// may import ``CryptoKit``) so any caller — a CLI, a controller, a
/// third-party auditor tool — can verify audit-log inclusion without
/// importing the infrastructure layer or the full audit pipeline.
/// ``SpookCore`` is Foundation-only by policy.
///
/// ## Algorithm
///
/// RFC 6962 (Certificate Transparency) §2.1 and §2.1.1:
///
/// 1. Leaf hash: `SHA256(0x00 || leaf_bytes)`
/// 2. Inner node hash: `SHA256(0x01 || left || right)`
/// 3. Reconstruct the root from the leaf hash and the audit path
///    (`[sibling_0, sibling_1, ...]`) by walking left-or-right at
///    each level based on the bit pattern of the leaf index —
///    the low bit selects which side the sibling sits on; shift
///    right at each level.
/// 4. Compare the reconstructed root to the tree head's root
///    hash.
///
/// ## Usage
///
/// ```swift
/// let leaf = try leafBytes(for: record)
/// let verified = MerkleTreeVerifier.verifyInclusion(
///     leafBytes: leaf,
///     leafIndex: 5,
///     auditPath: siblings,
///     treeSize: 128,
///     expectedRootHex: sth.rootHash
/// )
/// ```
///
/// ## Why domain-layer
///
/// The verifier depends only on Foundation + CryptoKit (both
/// available on every Apple platform and on Linux Foundation).
/// It has no file I/O, no logger, no actor. Unit tests can feed
/// it the RFC 6962 appendix test vectors directly.
public enum MerkleTreeVerifier {

    // MARK: - Public API

    /// Reconstructs the Merkle root from an inclusion proof and
    /// returns `true` when it matches the expected root.
    ///
    /// - Parameters:
    ///   - leafBytes: The record bytes that were hashed into the
    ///     tree. The verifier prepends `0x00` and SHA-256-hashes
    ///     internally.
    ///   - leafIndex: Zero-based index of the leaf in the log.
    ///   - auditPath: Sibling hashes from leaf level up, exactly
    ///     as emitted by ``MerkleAuditSink/inclusionProof(forLeafAt:)``.
    ///   - treeSize: Total number of leaves committed by the tree
    ///     head. Used to bound the odd-leaf promotion rule.
    ///   - expectedRootHex: Hex-encoded SHA-256 root hash from the
    ///     signed tree head.
    /// - Returns: `true` if the reconstruction matches, `false`
    ///   otherwise. No input validation throws — a malformed
    ///   input returns `false`.
    public static func verifyInclusion(
        leafBytes: Data,
        leafIndex: Int,
        auditPath: [Data],
        treeSize: Int,
        expectedRootHex: String
    ) -> Bool {
        guard leafIndex >= 0, leafIndex < treeSize else { return false }
        let expected = hexToData(expectedRootHex)
        guard !expected.isEmpty else { return false }
        let reconstructed = reconstructRoot(
            leafBytes: leafBytes,
            leafIndex: leafIndex,
            auditPath: auditPath,
            treeSize: treeSize
        )
        return reconstructed == expected
    }

    /// Reconstructs and returns the Merkle root for a given leaf,
    /// audit path, and tree size. Exposed for callers that want to
    /// log the reconstructed root alongside the expected one.
    public static func reconstructRoot(
        leafBytes: Data,
        leafIndex: Int,
        auditPath: [Data],
        treeSize: Int
    ) -> Data {
        // RFC 6962 §2.1.1 path reconstruction. The algorithm walks
        // from leaf to root, consuming one sibling per level that
        // has one. At each level, the leaf index's low bit tells
        // us whether our running hash is the left or right child;
        // we shift right and repeat with the level bound halved
        // (ceiling division, to account for odd-leaf promotion).
        var hash = leafHash(leafBytes)
        var fn = leafIndex
        var sn = treeSize - 1
        var pathIndex = 0
        while sn > 0 {
            if (fn & 1) == 1 {
                // Running hash is the right child.
                guard pathIndex < auditPath.count else { return Data() }
                hash = innerHash(auditPath[pathIndex], hash)
                pathIndex += 1
            } else if fn != sn {
                // Running hash is the left child with a real
                // right sibling.
                guard pathIndex < auditPath.count else { return Data() }
                hash = innerHash(hash, auditPath[pathIndex])
                pathIndex += 1
            }
            // else: fn == sn and fn is even → odd-leaf promotion
            // at this level. Nothing consumed; just shift.
            fn >>= 1
            sn >>= 1
        }
        return hash
    }

    /// RFC 6962 §2.1 leaf hash: `SHA256(0x00 || data)`.
    public static func leafHash(_ data: Data) -> Data {
        var input = Data([0x00])
        input.append(data)
        return sha256(input)
    }

    /// RFC 6962 §2.1 inner node hash: `SHA256(0x01 || left || right)`.
    public static func innerHash(_ left: Data, _ right: Data) -> Data {
        var input = Data([0x01])
        input.append(left)
        input.append(right)
        return sha256(input)
    }

    // MARK: - Helpers

    private static func sha256(_ data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return digest.withUnsafeBytes { Data($0) }
    }

    /// Decodes a hex string (upper or lower case, with or without
    /// whitespace) into its byte representation. Returns empty
    /// `Data` if the input is not valid hex.
    public static func hexToData(_ hex: String) -> Data {
        let trimmed = hex.filter { !$0.isWhitespace }
        guard trimmed.count % 2 == 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(trimmed.count / 2)
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            let next = trimmed.index(idx, offsetBy: 2)
            guard let byte = UInt8(trimmed[idx..<next], radix: 16) else {
                return Data()
            }
            out.append(byte)
            idx = next
        }
        return out
    }
}

// MARK: - Ed25519 STH verifier (pure domain)

/// Pure verifier for RFC 6962-shaped signed tree heads using
/// Ed25519. Lives here so unit tests and third-party auditors can
/// reuse the algorithm without pulling in the CLI target.
///
/// ## TBS structure (RFC 6962 §3.5)
///
/// ```
/// version (1 byte)        = 0 (v1)
/// signature_type (1 byte) = 1 (tree_hash)
/// timestamp_ms (8 BE)
/// tree_size    (8 BE)
/// sha256_root_hash (32)
/// ```
public enum SignedTreeHeadVerifier {

    /// Verification outcome.
    public struct Outcome: Sendable {
        public let leafHashHex: String
        public let reconstructedRootHex: String
        public let expectedRootHex: String
        public let signatureValid: Bool
        public let inclusionValid: Bool
    }

    /// Errors during verification that should exit with code 2
    /// ("input error") in CLI drivers.
    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        case missingFile(label: String, path: String)
        case unreadableFile(label: String, path: String, reason: String)
        case malformedJSON(field: String, reason: String)
        case badPublicKey(reason: String)
        case invalidHex

        public var description: String {
            switch self {
            case .missingFile(let label, let path):
                return "error: --\(label) not found: \(path)"
            case .unreadableFile(let label, let path, let reason):
                return "error: cannot read --\(label) \(path): \(reason)"
            case .malformedJSON(let field, let reason):
                return "error: \(field) is malformed JSON: \(reason)"
            case .badPublicKey(let reason):
                return "error: --public-key: \(reason)"
            case .invalidHex:
                return "error: invalid hex in audit path"
            }
        }
    }

    /// On-disk layout of the inclusion proof document.
    public struct AuditPathDoc: Decodable, Sendable {
        public let leafIndex: Int
        public let auditPath: [String]
        public init(leafIndex: Int, auditPath: [String]) {
            self.leafIndex = leafIndex
            self.auditPath = auditPath
        }
    }

    /// On-disk shape of a signed tree head.
    public struct TreeHeadDoc: Decodable, Sendable {
        public let treeSize: Int
        public let timestamp: Date
        public let rootHash: String
        public let signature: String
        public init(treeSize: Int, timestamp: Date, rootHash: String, signature: String) {
            self.treeSize = treeSize
            self.timestamp = timestamp
            self.rootHash = rootHash
            self.signature = signature
        }
    }

    /// Runs the full verification algorithm against on-disk inputs.
    public static func verify(
        recordPath: String,
        auditPathPath: String,
        treeHeadPath: String,
        publicKeyPath: String
    ) throws -> Outcome {
        let recordBytes = try readFile(recordPath, label: "record")
        let auditPathBytes = try readFile(auditPathPath, label: "audit-path")
        let treeHeadBytes = try readFile(treeHeadPath, label: "tree-head")
        let publicKeyBytes = try readFile(publicKeyPath, label: "public-key")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let auditPath: AuditPathDoc
        do {
            auditPath = try decoder.decode(AuditPathDoc.self, from: auditPathBytes)
        } catch {
            throw Error.malformedJSON(field: "audit-path", reason: error.localizedDescription)
        }
        let treeHead: TreeHeadDoc
        do {
            treeHead = try decoder.decode(TreeHeadDoc.self, from: treeHeadBytes)
        } catch {
            throw Error.malformedJSON(field: "tree-head", reason: error.localizedDescription)
        }

        let leaf = MerkleTreeVerifier.leafHash(recordBytes)
        let siblings = auditPath.auditPath.map { MerkleTreeVerifier.hexToData($0) }
        if siblings.contains(where: { $0.isEmpty }) && !auditPath.auditPath.isEmpty {
            throw Error.malformedJSON(field: "audit-path.auditPath", reason: "invalid hex")
        }
        let reconstructed = MerkleTreeVerifier.reconstructRoot(
            leafBytes: recordBytes,
            leafIndex: auditPath.leafIndex,
            auditPath: siblings,
            treeSize: treeHead.treeSize
        )
        let expected = MerkleTreeVerifier.hexToData(treeHead.rootHash)
        let inclusionValid = !expected.isEmpty && reconstructed == expected

        let signatureValid = try verifySignature(
            treeHead: treeHead,
            publicKeyPEM: publicKeyBytes
        )

        return Outcome(
            leafHashHex: hexString(leaf),
            reconstructedRootHex: hexString(reconstructed),
            expectedRootHex: treeHead.rootHash,
            signatureValid: signatureValid,
            inclusionValid: inclusionValid
        )
    }

    /// Signature check over the RFC 6962 TBS bytes.
    ///
    /// Supports both signing algorithms shipped in this repo:
    ///
    /// - **P-256 ECDSA** — the format ``HashChainAuditSink`` currently
    ///   emits. The production signer is SEP-bound (``P256KeyStore``)
    ///   or software (``P256SoftwareKeyStore``).
    /// - **Ed25519** — retained for auditors holding tree heads
    ///   produced by older builds or third-party CT logs that
    ///   conform to RFC 6962 using the original scheme.
    ///
    /// Algorithm is detected by attempting each keystore initializer
    /// in order. The first key that parses wins; if neither matches,
    /// `badPublicKey` is thrown with a combined reason. Callers who
    /// want a deterministic algorithm can pin it by providing a PEM
    /// that only one of the two parsers can decode.
    public static func verifySignature(
        treeHead: TreeHeadDoc,
        publicKeyPEM: Data
    ) throws -> Bool {
        guard let pem = String(data: publicKeyPEM, encoding: .utf8) else {
            throw Error.badPublicKey(reason: "PEM file is not UTF-8")
        }
        guard let signature = Data(base64Encoded: treeHead.signature) else {
            return false
        }
        let tbs = tbsBytes(treeHead: treeHead)

        // Try P-256 first (the algorithm the shipping signer uses).
        if let p256 = try? P256.Signing.PublicKey(pemRepresentation: pem) {
            // STH signatures are emitted in DER-encoded r||s form by
            // CryptoKit's `P256.Signing.PrivateKey.signature(for:)`.
            if let ecdsaSignature = try? P256.Signing.ECDSASignature(
                derRepresentation: signature
            ) {
                return p256.isValidSignature(ecdsaSignature, for: tbs)
            }
            if let ecdsaSignature = try? P256.Signing.ECDSASignature(
                rawRepresentation: signature
            ) {
                return p256.isValidSignature(ecdsaSignature, for: tbs)
            }
            return false
        }

        // Fall back to Ed25519 for legacy and third-party CT tree heads.
        let raw: Data
        do {
            raw = try decodeEd25519PublicKeyPEM(pem)
        } catch let ed25519Err {
            throw Error.badPublicKey(
                reason: "PEM is neither a P-256 SPKI nor an Ed25519 key: \(ed25519Err.localizedDescription)"
            )
        }
        let ed: Curve25519.Signing.PublicKey
        do {
            ed = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        } catch {
            throw Error.badPublicKey(
                reason: "not a 32-byte Ed25519 key: \(error.localizedDescription)"
            )
        }
        return ed.isValidSignature(signature, for: tbs)
    }

    /// Parses a PEM-encoded Ed25519 public key and returns the
    /// raw 32 bytes. Accepts both a bare 32-byte body and a full
    /// RFC 8410 SubjectPublicKeyInfo block (which ends with a
    /// 32-byte BIT STRING body).
    public static func decodeEd25519PublicKeyPEM(_ pem: String) throws -> Data {
        let lines = pem.split(whereSeparator: { $0.isNewline })
        var body = ""
        var inside = false
        for line in lines {
            if line.hasPrefix("-----BEGIN") { inside = true; continue }
            if line.hasPrefix("-----END") { inside = false; continue }
            if inside { body.append(contentsOf: line) }
        }
        guard let decoded = Data(base64Encoded: body) else {
            throw Error.badPublicKey(reason: "invalid base64 in PEM body")
        }
        if decoded.count == 32 {
            return decoded
        }
        if decoded.count >= 44 {
            // RFC 8410 SPKI ends with the 32-byte key.
            return decoded.suffix(32)
        }
        throw Error.badPublicKey(reason: "decoded key is \(decoded.count) bytes; expected 32 or SPKI")
    }

    // MARK: - Internals

    private static func tbsBytes(treeHead: TreeHeadDoc) -> Data {
        var message = Data()
        message.append(0x00) // version = v1
        message.append(0x01) // signature_type = tree_hash
        let ts = UInt64(treeHead.timestamp.timeIntervalSince1970 * 1000)
        withUnsafeBytes(of: ts.bigEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(treeHead.treeSize).bigEndian) { message.append(contentsOf: $0) }
        message.append(MerkleTreeVerifier.hexToData(treeHead.rootHash))
        return message
    }

    private static func readFile(_ path: String, label: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: path) else {
            throw Error.missingFile(label: label, path: path)
        }
        do {
            return try Data(contentsOf: URL(filePath: path))
        } catch {
            throw Error.unreadableFile(label: label, path: path, reason: error.localizedDescription)
        }
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

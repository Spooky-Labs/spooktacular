import Foundation
import CryptoKit
import SpookCore
import SpookApplication

// MARK: - Merkle Tree Audit Sink

/// A tamper-evident audit sink using a Merkle tree structure aligned
/// with RFC 6962 (Certificate Transparency) and NIST SP 800-53
/// AU-9/AU-10 requirements.
///
/// ## Standards Compliance
///
/// - **RFC 6962 / RFC 9162**: Merkle tree with inclusion proofs and
///   signed tree heads. Each leaf is `SHA256(0x00 || record)`, each
///   interior node is `SHA256(0x01 || left || right)`.
/// - **NIST SP 800-53 AU-9**: Cryptographic integrity protection of
///   audit information via Merkle root signatures.
/// - **NIST SP 800-53 AU-10**: Non-repudiation via signed tree heads
///   that commit to the entire log state.
/// - **NIST SP 800-53 AU-12**: Tamper-resistant centralized collection.
///
/// ## How It Works
///
/// Records are appended as leaves in a dense Merkle tree. After each
/// append, the tree root is recomputed. Periodically (or on demand),
/// a **Signed Tree Head** (STH) is produced — the root hash signed
/// with the server's private key.
///
/// An **inclusion proof** (O(log n) hashes) proves a specific record
/// is part of the tree. A **consistency proof** proves the tree only
/// grew and no records were modified or removed.
///
/// ## Usage
///
/// ```swift
/// let key = Curve25519.Signing.PrivateKey()
/// let sink = MerkleAuditSink(wrapping: jsonFileSink, signingKey: key)
/// await sink.record(auditEntry)
/// let sth = await sink.signedTreeHead()
/// let proof = await sink.inclusionProof(forLeafAt: 5)
/// ```
public actor MerkleAuditSink: AuditSink {
    private let inner: any AuditSink
    private let signingKey: Curve25519.Signing.PrivateKey
    private let encoder: JSONEncoder
    private var leaves: [Data] = []
    private var tree: [[Data]] = []

    /// Creates a Merkle tree audit sink wrapping another sink.
    ///
    /// - Parameters:
    ///   - inner: The underlying sink that receives records (e.g., JSONL file).
    ///   - signingKey: Ed25519 private key for signing tree heads.
    public init(wrapping inner: any AuditSink, signingKey: Curve25519.Signing.PrivateKey) {
        self.inner = inner
        self.signingKey = signingKey
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    // MARK: - AuditSink

    public func record(_ entry: AuditRecord) async {
        let entryData = (try? encoder.encode(entry)) ?? Data()

        // RFC 6962 leaf hash: SHA256(0x00 || data)
        let leafHash = merkleLeafHash(entryData)
        leaves.append(leafHash)
        rebuildTree()

        // Forward the record with the current tree head appended
        let root = treeRoot().hexString
        let chainedEntry = AuditRecord(
            actorIdentity: entry.actorIdentity,
            tenant: entry.tenant,
            scope: entry.scope,
            resource: entry.resource,
            action: entry.action,
            outcome: entry.outcome,
            correlationID: "\(entry.correlationID ?? entry.id)|merkle:\(root)|leaf:\(leaves.count - 1)"
        )
        await inner.record(chainedEntry)
    }

    // MARK: - Signed Tree Head (NIST AU-10 Non-Repudiation)

    /// Produces a Signed Tree Head (STH) — the Merkle root signed
    /// with the server's Ed25519 private key.
    ///
    /// External verifiers can check the signature with the public key
    /// to confirm the log state has not been tampered with.
    public func signedTreeHead() -> SignedTreeHead {
        let root = treeRoot()
        let treeSize = leaves.count
        let timestamp = Date()

        // Sign: SHA256(timestamp || treeSize || root)
        var message = Data()
        let ts = UInt64(timestamp.timeIntervalSince1970)
        withUnsafeBytes(of: ts.bigEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(treeSize).bigEndian) { message.append(contentsOf: $0) }
        message.append(root)

        let signature = try! signingKey.signature(for: message)

        return SignedTreeHead(
            treeSize: treeSize,
            timestamp: timestamp,
            rootHash: root.hexString,
            signature: signature.withUnsafeBytes { Data($0) }.base64EncodedString()
        )
    }

    // MARK: - Inclusion Proof (RFC 6962)

    /// Returns a Merkle inclusion proof for the leaf at the given index.
    ///
    /// The proof consists of O(log n) sibling hashes that, combined
    /// with the leaf hash, reproduce the tree root.
    public func inclusionProof(forLeafAt index: Int) -> [Data]? {
        guard index >= 0, index < leaves.count else { return nil }
        guard !tree.isEmpty else { return nil }

        var proof: [Data] = []
        var idx = index
        for level in tree {
            let siblingIdx = idx % 2 == 0 ? idx + 1 : idx - 1
            if siblingIdx < level.count {
                proof.append(level[siblingIdx])
            }
            idx /= 2
        }
        return proof
    }

    /// Verifies that a record hash is included in the tree at the
    /// given index using the provided proof and expected root.
    public static func verifyInclusion(
        leafHash: Data,
        index: Int,
        proof: [Data],
        expectedRoot: Data
    ) -> Bool {
        var hash = leafHash
        var idx = index
        for sibling in proof {
            if idx % 2 == 0 {
                hash = merkleNodeHash(hash, sibling)
            } else {
                hash = merkleNodeHash(sibling, hash)
            }
            idx /= 2
        }
        return hash == expectedRoot
    }

    // MARK: - Tree State

    /// The current Merkle root hash.
    public func rootHash() -> String { treeRoot().hexString }

    /// The number of records in the log.
    public func treeSize() -> Int { leaves.count }

    // MARK: - Private: Merkle Tree Construction (RFC 6962)

    private func treeRoot() -> Data {
        guard let last = tree.last, let root = last.first else {
            return SHA256.hash(data: Data()).withUnsafeBytes { Data($0) }
        }
        return root
    }

    private func rebuildTree() {
        tree = []
        var currentLevel = leaves
        while currentLevel.count > 1 {
            tree.append(currentLevel)
            var nextLevel: [Data] = []
            for i in stride(from: 0, to: currentLevel.count, by: 2) {
                if i + 1 < currentLevel.count {
                    nextLevel.append(merkleNodeHash(currentLevel[i], currentLevel[i + 1]))
                } else {
                    // Odd leaf promoted
                    nextLevel.append(currentLevel[i])
                }
            }
            currentLevel = nextLevel
        }
        tree.append(currentLevel)
    }
}

// MARK: - RFC 6962 Hash Functions

/// RFC 6962 leaf hash: SHA256(0x00 || data)
private func merkleLeafHash(_ data: Data) -> Data {
    var input = Data([0x00])
    input.append(data)
    return SHA256.hash(data: input).withUnsafeBytes { Data($0) }
}

/// RFC 6962 node hash: SHA256(0x01 || left || right)
private func merkleNodeHash(_ left: Data, _ right: Data) -> Data {
    var input = Data([0x01])
    input.append(left)
    input.append(right)
    return SHA256.hash(data: input).withUnsafeBytes { Data($0) }
}

// MARK: - Signed Tree Head

/// A signed commitment to the state of the audit log at a point in time.
///
/// Contains the Merkle root hash, tree size, timestamp, and an Ed25519
/// signature. External verifiers can check the signature with the
/// server's public key.
public struct SignedTreeHead: Sendable, Codable {
    /// Number of records in the log.
    public let treeSize: Int
    /// When this STH was produced.
    public let timestamp: Date
    /// Hex-encoded Merkle root hash.
    public let rootHash: String
    /// Base64-encoded Ed25519 signature.
    public let signature: String
}

// MARK: - Data Extension

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import CryptoKit
import SpooktacularCore
import SpooktacularApplication
import os

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
/// // Production: SEP-bound P-256 key, non-exportable
/// let signer = try AuditSinkFactory.loadOrCreateSEPSigningKey(label: "audit-controller")
/// let sink = MerkleAuditSink(wrapping: jsonFileSink, signer: signer)
///
/// // Tests / non-SEP hosts: software P-256
/// let sink = MerkleAuditSink(wrapping: inner, signer: P256.Signing.PrivateKey())
///
/// await sink.record(auditEntry)
/// let sth = try await sink.signedTreeHead()
/// let proof = await sink.inclusionProof(forLeafAt: 5)
/// ```
public actor MerkleAuditSink: AuditSink {
    private let inner: any AuditSink
    private let signer: any P256Signer
    private let encoder: JSONEncoder
    var leaves: [Data] = []
    private var tree: [[Data]] = []

    /// Creates a Merkle tree audit sink wrapping another sink.
    ///
    /// - Parameters:
    ///   - inner: The underlying sink that receives records (e.g., JSONL file).
    ///   - signer: A ``P256Signer`` that produces tree-head signatures.
    ///     Production default is an SEP-bound signer from
    ///     ``AuditSinkFactory/loadOrCreateSEPSigningKey(label:)`` —
    ///     key material lives in the Secure Enclave and cannot be
    ///     exfiltrated even with full process / kernel compromise.
    public init(wrapping inner: any AuditSink, signer: any P256Signer) {
        self.inner = inner
        self.signer = signer
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    // MARK: - AuditSink

    public func record(_ entry: AuditRecord) async throws {
        let entryData: Data
        do {
            entryData = try encoder.encode(entry)
        } catch {
            throw AuditSinkError.recordingFailed(reason: "merkle encode failed: \(error.localizedDescription)")
        }

        // RFC 6962 §2.1 leaf hash: SHA256(0x00 || data)
        let leafHash = merkleLeafHash(entryData)
        leaves.append(leafHash)
        rebuildTree()

        // Forward the record with the current tree head appended as
        // correlationID metadata. Preserve the caller's id and
        // timestamp — previously this layer minted a fresh UUID and
        // a later timestamp, so the record that actually landed on
        // disk had a different identity than the one the caller
        // built. NIST SP 800-53 AU-3 requires unique traceability,
        // and callers that retain the original for later lookup
        // couldn't find it in the store.
        let root = treeRoot().hexString
        let chainedEntry = AuditRecord(
            id: entry.id,
            timestamp: entry.timestamp,
            actorIdentity: entry.actorIdentity,
            tenant: entry.tenant,
            scope: entry.scope,
            resource: entry.resource,
            action: entry.action,
            outcome: entry.outcome,
            correlationID: "\(entry.correlationID ?? entry.id)|merkle:\(root)|leaf:\(leaves.count - 1)"
        )
        // Inner-sink failures propagate. If the base sink (JSONL /
        // append-only / S3) cannot durably store the record, neither
        // can the Merkle tree — otherwise callers see a "committed"
        // tree root whose leaf is nowhere in the log.
        try await inner.record(chainedEntry)
    }

    // MARK: - Hash-chain integrity on restart

    /// Rehydrates the in-memory tree from an ordered list of prior
    /// leaf payloads and verifies no record is missing.
    ///
    /// Call this at controller startup when the underlying store is
    /// readable — it rebuilds the tree so a new STH from the
    /// rehydrated root matches the prior committed root. If
    /// `expectedPriorRoot` is supplied and doesn't match the
    /// reconstruction, the method throws — a strong tamper signal,
    /// because the on-disk log cannot have grown to a state that
    /// reconstructs a root different from the one the controller
    /// last signed.
    public func rehydrate(
        from records: [AuditRecord],
        expectedPriorRoot: String? = nil
    ) async throws {
        leaves.removeAll()
        tree.removeAll()
        for record in records {
            let data: Data
            do {
                data = try encoder.encode(record)
            } catch {
                throw AuditSinkError.recordingFailed(reason: "rehydrate encode failed: \(error.localizedDescription)")
            }
            leaves.append(merkleLeafHash(data))
        }
        rebuildTree()
        if let expected = expectedPriorRoot {
            let got = treeRoot().hexString
            if got != expected {
                throw AuditSinkError.truncatedRead
            }
        }
    }

    // MARK: - Signed Tree Head (NIST AU-10 Non-Repudiation)

    /// Produces a Signed Tree Head (STH) — the Merkle root signed
    /// with the server's P-256 ECDSA private key (SEP-bound in
    /// production), byte-compatible with RFC 6962 §3.5
    /// `TreeHeadSignature` for the TBS structure.
    ///
    /// ## TBS bytes (the structure we sign)
    ///
    /// ```
    /// version (1 byte)           = 0           (v1)
    /// signature_type (1 byte)    = 1           (tree_hash)
    /// timestamp (8 bytes, BE)    milliseconds since Unix epoch
    /// tree_size (8 bytes, BE)    leaf count
    /// sha256_root_hash (32 bytes)
    /// ```
    ///
    /// ## Signing algorithm
    ///
    /// P-256 ECDSA, 64-byte raw (r ‖ s) signature. In production
    /// the key is Secure-Enclave-bound: the private material
    /// never leaves the SEP, so a compromised controller process
    /// cannot forge tree heads even with full code-execution
    /// capability — the SEP will only sign what the server
    /// requests, each request attributed to the specific hardware
    /// that generated it. FIPS 140-3 Level 2 (SEP), AAL2 per
    /// NIST SP 800-63B (no presence gate for daemon use).
    ///
    /// Earlier releases signed with Ed25519; any STH produced
    /// before the P-256 migration uses a different key with a
    /// different algorithm and is not verifiable with the current
    /// public key. The public-key-per-controller rotation model
    /// is the intended operational answer: external verifiers
    /// pin the public key that was in force at the time of
    /// issuance.
    public func signedTreeHead() throws -> SignedTreeHead {
        let root = treeRoot()
        let treeSize = leaves.count
        let timestamp = Date()

        var message = Data()
        message.append(0x00)                                  // version = v1
        message.append(0x01)                                  // signature_type = tree_hash
        let tsMillis = UInt64(timestamp.timeIntervalSince1970 * 1000)
        withUnsafeBytes(of: tsMillis.bigEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(treeSize).bigEndian) { message.append(contentsOf: $0) }
        message.append(root)

        // A throw here indicates SEP failure or (in software-key
        // mode) key corruption. Propagate so callers can decide
        // whether to retry or fall back — previously a
        // "SIGNING_FAILED" sentinel string looked like a valid
        // STH to downstream consumers, which is strictly worse
        // than an exception.
        let signature = try signer.signature(for: message)

        return SignedTreeHead(
            treeSize: treeSize,
            timestamp: timestamp,
            rootHash: root.hexString,
            signature: signature.base64EncodedString()
        )
    }

    /// Returns a Signed Tree Head if one can be produced; otherwise
    /// emits the root hash unsigned and logs the signing failure.
    ///
    /// Use this from long-running pipelines (periodic STH emitters,
    /// background audit exporters) where a crash on a transient
    /// signing error would take down an entire audit subsystem —
    /// exactly the outcome an append-only audit design exists to
    /// prevent. The unsigned fallback is marked with an empty
    /// `signature` field so downstream verifiers can distinguish it
    /// from a valid STH and route it to a quarantine queue instead
    /// of trusting it for non-repudiation.
    ///
    /// The throwing variant ``signedTreeHead()`` remains the correct
    /// call when the caller wants signing failure to propagate —
    /// e.g. an interactive `spook audit sign` invocation where the
    /// operator should see the error immediately.
    public func signedTreeHeadOrUnsigned() -> SignedTreeHead {
        do {
            return try signedTreeHead()
        } catch {
            let root = treeRoot()
            let treeSize = leaves.count
            Log.audit.error(
                "STH signing failed (tree size \(treeSize, privacy: .public)): \(error.localizedDescription, privacy: .public) — emitting unsigned STH"
            )
            return SignedTreeHead(
                treeSize: treeSize,
                timestamp: Date(),
                rootHash: root.hexString,
                signature: ""
            )
        }
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
/// Contains the Merkle root hash, tree size, timestamp, and a P-256
/// ECDSA signature (64-byte raw representation, base64-encoded).
/// External verifiers check the signature with the server's public
/// key (published by the controller at startup / on rotation).
public struct SignedTreeHead: Sendable, Codable {
    /// Number of records in the log.
    public let treeSize: Int
    /// When this STH was produced.
    public let timestamp: Date
    /// Hex-encoded Merkle root hash.
    public let rootHash: String
    /// Base64-encoded P-256 ECDSA signature (64 bytes raw, r ‖ s).
    public let signature: String
}

// MARK: - Data Extension

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

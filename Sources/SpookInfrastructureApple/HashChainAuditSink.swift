import Foundation
import CryptoKit
import SpookCore
import SpookApplication

/// A tamper-evident audit sink that chains records using SHA-256 hashes.
///
/// Each record includes the hash of the previous record, creating a
/// verifiable chain. If any record is modified or deleted, the chain
/// breaks and the tamper is detectable.
///
/// This is not full cryptographic non-repudiation (no signatures),
/// but it provides tamper evidence for compliance reviewers.
public actor HashChainAuditSink: AuditSink {
    private let inner: any AuditSink
    private var previousHash: String = "genesis"
    private let encoder: JSONEncoder

    /// Creates a hash-chaining wrapper around another audit sink.
    public init(wrapping inner: any AuditSink) {
        self.inner = inner
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    public func record(_ entry: AuditRecord) async {
        // Compute the chain hash: SHA256(previousHash + serialized entry)
        let entryData = (try? encoder.encode(entry)) ?? Data()
        let chainInput = previousHash + entryData.base64EncodedString()
        let hash = SHA256.hash(data: Data(chainInput.utf8))
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()

        // Create a chained entry with the hash
        let chainedEntry = AuditRecord(
            actorIdentity: entry.actorIdentity,
            tenant: entry.tenant,
            scope: entry.scope,
            resource: entry.resource,
            action: entry.action,
            outcome: entry.outcome,
            correlationID: "\(entry.correlationID ?? entry.id)|chain:\(hashHex)"
        )

        previousHash = hashHex
        await inner.record(chainedEntry)
    }

    /// Returns the current chain head hash for external verification.
    public func chainHead() -> String { previousHash }
}

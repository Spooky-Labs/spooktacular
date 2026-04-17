import Foundation
import CryptoKit
import SpookCore
import SpookApplication

// Hex → Data helper for the webhook's HMAC key.
extension Data {
    fileprivate init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespaces)
        guard clean.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self = Data(bytes)
    }
}

/// Factory that composes audit sinks from configuration.
///
/// Eliminates duplicated sink-chain construction between the CLI
/// (`spook serve`) and the Kubernetes controller. Both call
/// `AuditSinkFactory.build(config:)` instead of manually reading
/// environment variables and composing sinks.
///
/// ## Sink chain
///
/// ```
/// Base sink (JSONL or OSLog)
///   → optional AppendOnlyFileAuditStore (UF_APPEND)
///     → optional MerkleAuditSink (RFC 6962, P-256 ECDSA, SEP-bound)
///       → optional S3ObjectLockAuditStore (WORM, teed off)
/// ```
///
/// ## Merkle signing key selection
///
/// When Merkle is enabled, the factory delegates to
/// ``P256KeyStore``, picking between SEP-bound and software
/// paths based on which of the two config fields is set:
///
/// 1. `config.merkleSigningKeyLabel` — SEP-bound key under the
///    `com.spooktacular.merkle-audit` service namespace. The
///    daemon signs continuously so no presence gate is used.
/// 2. `config.merkleSigningKeyPath` — PEM-encoded software key
///    at file mode 0600. Fallback for non-SEP hosts and tests.
///
/// Requiring exactly one is intentional: silent fall-through
/// to an ephemeral key would produce STHs that don't verify
/// after restart.
public enum AuditSinkFactory {

    /// Builds an audit sink chain from the given configuration.
    public static func build(config: AuditConfig) async throws -> (any AuditSink)? {
        // Base sink
        var sink: (any AuditSink)?
        if let filePath = config.filePath {
            sink = try JSONFileAuditSink(path: filePath)
        }

        // Append-only immutable store
        if let immutablePath = config.immutablePath {
            let immutable = try AppendOnlyFileAuditStore(path: immutablePath)
            if let base = sink {
                sink = DualAuditSink(primary: base, secondary: immutable)
            } else {
                sink = immutable
            }
        }

        // Merkle tree tamper-evidence — SEP-bound in production.
        if config.merkleEnabled, let base = sink {
            let signer = try await resolveMerkleSigner(config: config)
            sink = MerkleAuditSink(wrapping: base, signer: signer)
        }

        // S3 Object Lock (WORM) — tee into the chain.
        if let bucket = config.s3Bucket {
            let s3 = try S3ObjectLockAuditStore(
                bucket: bucket,
                region: config.s3Region ?? "us-east-1",
                prefix: config.s3Prefix ?? "audit/",
                retentionDays: config.s3RetentionDays ?? 2555,
                batchSize: config.s3BatchSize ?? 100
            )
            if let base = sink {
                sink = DualAuditSink(primary: base, secondary: s3)
            } else {
                sink = s3
            }
        }

        // SIEM webhook forwarder — tee into the chain.
        if let urlString = config.webhookURL, let url = URL(string: urlString) {
            let hmacKey: CryptoKit.SymmetricKey?
            if let hex = config.webhookHMACKeyHex,
               let data = Data(hexString: hex) {
                hmacKey = CryptoKit.SymmetricKey(data: data)
            } else {
                hmacKey = nil
            }
            let webhook = WebhookAuditSink(config: .init(
                url: url,
                hmacKey: hmacKey,
                extraHeaders: config.webhookExtraHeaders ?? [:]
            ))
            if let base = sink {
                sink = DualAuditSink(primary: base, secondary: webhook)
            } else {
                sink = webhook
            }
        }

        if sink == nil {
            sink = OSLogAuditSink()
        }

        return sink
    }

    /// Resolves the Merkle signing key from the configuration.
    /// Requires exactly one of the label / path options to be set.
    public static func resolveMerkleSigner(config: AuditConfig) async throws -> any P256Signer {
        let hasLabel = config.merkleSigningKeyLabel != nil
        let hasPath = config.merkleSigningKeyPath != nil
        switch (hasLabel, hasPath) {
        case (false, false):
            throw AuditSinkFactoryError.merkleKeyRequired
        case (true, true):
            throw AuditSinkFactoryError.merkleKeyAmbiguous
        case (true, false):
            guard let label = config.merkleSigningKeyLabel, !label.isEmpty else {
                throw AuditSinkFactoryError.merkleKeyLabelEmpty
            }
            return try await P256KeyStore.loadOrCreateSEP(
                service: P256KeyStore.Service.merkleAudit,
                label: label,
                presenceGated: false
            )
        case (false, true):
            return try P256KeyStore.loadOrCreateSoftware(at: config.merkleSigningKeyPath!)
        }
    }
}

// MARK: - Errors

/// Errors raised while composing an audit sink chain.
public enum AuditSinkFactoryError: Error, LocalizedError, Sendable {
    case merkleKeyRequired
    case merkleKeyAmbiguous
    case merkleKeyLabelEmpty

    public var errorDescription: String? {
        switch self {
        case .merkleKeyRequired:
            return "Merkle audit is enabled but neither SPOOK_AUDIT_SIGNING_KEY_LABEL (SEP-bound, recommended) nor SPOOK_AUDIT_SIGNING_KEY_PATH (software) is set. A persistent signing key is required so tree heads verify across restarts."
        case .merkleKeyAmbiguous:
            return "Both SPOOK_AUDIT_SIGNING_KEY_LABEL and SPOOK_AUDIT_SIGNING_KEY_PATH are set — choose exactly one. Prefer the label (Secure Enclave) in production."
        case .merkleKeyLabelEmpty:
            return "SPOOK_AUDIT_SIGNING_KEY_LABEL is set but empty."
        }
    }
}

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
/// ``P256KeyStore``, which is SEP-only:
///
/// - `config.merkleSigningKeyLabel` — SEP-bound key under the
///   `com.spooktacular.merkle-audit` service namespace. The
///   daemon signs continuously so no presence gate is used.
///
/// Requiring a label is intentional: silent fall-through to an
/// ephemeral key would produce STHs that don't verify after
/// restart. The legacy `config.merkleSigningKeyPath` software-key
/// path was removed in Phase 3 of the SEP migration — PEM-on-disk
/// keys are reachable by malware running as the logged-in user
/// (see docs/THREAT_MODEL.md), while SEP-bound keys are
/// hardware-isolated and non-extractable.
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
    /// Requires `SPOOK_AUDIT_SIGNING_KEY_LABEL` (the SEP Keychain
    /// label). The legacy software-key path via
    /// `SPOOK_AUDIT_SIGNING_KEY_PATH` has been removed — Apple's
    /// threat model for PEM-on-disk keys puts them in reach of
    /// malware running as the logged-in user, while SEP-bound
    /// keys are hardware-isolated.
    public static func resolveMerkleSigner(config: AuditConfig) async throws -> any P256Signer {
        guard let label = config.merkleSigningKeyLabel, !label.isEmpty else {
            throw AuditSinkFactoryError.merkleKeyLabelRequired
        }
        return try await P256KeyStore.loadOrCreateSEP(
            service: P256KeyStore.Service.merkleAudit,
            label: label,
            presenceGated: false
        )
    }
}

// MARK: - Errors

/// Errors raised while composing an audit sink chain.
public enum AuditSinkFactoryError: Error, LocalizedError, Sendable {
    case merkleKeyLabelRequired

    public var errorDescription: String? {
        switch self {
        case .merkleKeyLabelRequired:
            return "Merkle audit is enabled but SPOOK_AUDIT_SIGNING_KEY_LABEL is unset or empty. Set it to a non-empty Keychain label — the SEP-backed key will be generated on first use and reused thereafter. The legacy SPOOK_AUDIT_SIGNING_KEY_PATH software-key path has been removed."
        }
    }
}

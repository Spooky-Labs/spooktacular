import Foundation
import CryptoKit
import SpookCore
import SpookApplication

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
///     → optional MerkleAuditSink (RFC 6962)
///       → optional S3ObjectLockAuditStore (WORM, teed off)
/// ```
///
/// When `s3Bucket` is set, records are tee'd to the S3 Object
/// Lock store in addition to the local chain — a local JSONL
/// tail stays available for real-time monitoring while the
/// immutable WORM copy accumulates for SOC 2 retention.
public enum AuditSinkFactory {

    /// Builds an audit sink chain from the given configuration.
    ///
    /// - Parameter config: The audit configuration.
    /// - Returns: A composed `AuditSink`, or `nil` if no audit is configured.
    public static func build(config: AuditConfig) throws -> (any AuditSink)? {
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

        // Merkle tree tamper-evidence
        //
        // Requires a persistent signing key at
        // `SPOOK_AUDIT_SIGNING_KEY`. The tree heads we sign must
        // verify across process restarts — generating a fresh key
        // on every boot would make yesterday's signed tree head
        // unverifiable, which is strictly worse than having no
        // signature at all (false sense of non-repudiation).
        if config.merkleEnabled, let base = sink {
            guard let keyPath = config.merkleSigningKeyPath else {
                throw AuditSinkFactoryError.merkleKeyRequired
            }
            let signingKey = try Self.loadOrCreateSigningKey(at: keyPath)
            sink = MerkleAuditSink(wrapping: base, signingKey: signingKey)
        }

        // S3 Object Lock (WORM) — tee into the chain.
        //
        // Previously the factory didn't compose S3 at all, so
        // `s3Bucket: "..."` in config appeared to be honored but
        // silently did nothing. Now the sink is always in the chain
        // when configured; we tee rather than replace so local
        // observability stays live while S3 accumulates the
        // retained WORM copy.
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

        // If nothing configured, use OSLog as default
        if sink == nil {
            sink = OSLogAuditSink()
        }

        return sink
    }

    /// Builds from environment variables (backward compatible).
    public static func fromEnvironment() throws -> (any AuditSink)? {
        let config = SpooktacularConfig.fromEnvironment().audit
        return try build(config: config)
    }

    // MARK: - Signing key persistence

    /// Loads an Ed25519 signing key from disk, creating it on first
    /// run with restrictive permissions (owner read/write only).
    ///
    /// File layout: 32-byte raw private-key material. Using the raw
    /// representation keeps the format stable and lets the key be
    /// rotated by simply replacing the file — operators don't need
    /// to learn a Spooktacular-specific format.
    ///
    /// On creation the file is written with mode 0600; if it
    /// already exists with weaker permissions the loader refuses
    /// to proceed, forcing the operator to tighten access.
    ///
    /// Public so both `spook serve` and `spook-controller` can
    /// share the same key-provisioning semantics rather than each
    /// re-rolling the policy.
    public static func loadOrCreateSigningKey(at path: String) throws -> Curve25519.Signing.PrivateKey {
        let url = URL(filePath: path)
        let fm = FileManager.default

        if fm.fileExists(atPath: path) {
            let attrs = try fm.attributesOfItem(atPath: path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            guard mode & 0o077 == 0 else {
                throw AuditSinkFactoryError.merkleKeyPermissionsTooOpen(path: path, mode: mode)
            }
            let data = try Data(contentsOf: url)
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } else {
            let dir = url.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let newKey = Curve25519.Signing.PrivateKey()
            try newKey.rawRepresentation.write(to: url, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return newKey
        }
    }
}

// MARK: - Errors

/// Errors raised while composing an audit sink chain.
public enum AuditSinkFactoryError: Error, LocalizedError, Sendable {
    case merkleKeyRequired
    case merkleKeyPermissionsTooOpen(path: String, mode: UInt16)

    public var errorDescription: String? {
        switch self {
        case .merkleKeyRequired:
            return "Merkle audit is enabled but SPOOK_AUDIT_SIGNING_KEY is not set. A persistent signing-key path is required so tree heads verify across restarts."
        case .merkleKeyPermissionsTooOpen(let path, let mode):
            return String(
                format: "Merkle signing key at '%@' has permissions 0%o. Expected 0600 (owner-only). `chmod 600 %@` then retry.",
                path, mode, path
            )
        }
    }
}

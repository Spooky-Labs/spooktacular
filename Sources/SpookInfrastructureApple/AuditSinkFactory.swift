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
///       → optional S3ObjectLockAuditStore (WORM)
/// ```
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
        if config.merkleEnabled, let base = sink {
            let signingKey = Curve25519.Signing.PrivateKey()
            sink = MerkleAuditSink(wrapping: base, signingKey: signingKey)
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
}

import Foundation
import CryptoKit
import Security
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
///     → optional MerkleAuditSink (RFC 6962, P-256 ECDSA, SEP-bound)
///       → optional S3ObjectLockAuditStore (WORM, teed off)
/// ```
///
/// ## Merkle signing key selection
///
/// When Merkle is enabled, the factory resolves a signer in this
/// order:
///
/// 1. `config.merkleSigningKeyLabel` — Secure-Enclave-bound P-256
///    key stored in the Keychain under the given label. Production
///    default on any host with an SEP (Apple Silicon or Intel Mac
///    with T2). Private key material never leaves the SEP; tree
///    heads are signed via IPC to the Secure Enclave Processor.
/// 2. `config.merkleSigningKeyPath` — PEM-encoded software P-256
///    private key at file mode 0600. Fallback for CI environments,
///    unit tests, and hosts without a Secure Enclave.
///
/// Requiring exactly one of the two is intentional: silent
/// fall-through to an ephemeral key would produce STHs that don't
/// verify after restart, which is strictly worse than refusing to
/// start with a clear error.
public enum AuditSinkFactory {

    /// Builds an audit sink chain from the given configuration.
    ///
    /// - Parameter config: The audit configuration.
    /// - Returns: A composed `AuditSink`, or an OSLog fallback if nothing is configured.
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

        // Merkle tree tamper-evidence — SEP-bound in production.
        if config.merkleEnabled, let base = sink {
            let signer = try resolveMerkleSigner(config: config)
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

        // If nothing configured, use OSLog as default
        if sink == nil {
            sink = OSLogAuditSink()
        }

        return sink
    }

    // MARK: - Merkle signer resolution

    /// Resolves the Merkle signing key from the configuration.
    /// Requires exactly one of the label / path options to be set.
    public static func resolveMerkleSigner(config: AuditConfig) throws -> any P256Signer {
        let hasLabel = config.merkleSigningKeyLabel != nil
        let hasPath = config.merkleSigningKeyPath != nil
        switch (hasLabel, hasPath) {
        case (false, false):
            throw AuditSinkFactoryError.merkleKeyRequired
        case (true, true):
            throw AuditSinkFactoryError.merkleKeyAmbiguous
        case (true, false):
            return try loadOrCreateSEPSigningKey(label: config.merkleSigningKeyLabel!)
        case (false, true):
            return try loadOrCreateSoftwareSigningKey(at: config.merkleSigningKeyPath!)
        }
    }

    // MARK: - SEP-bound signer (production)

    /// Keychain attribute service tag for the Merkle signing key.
    public static let merkleKeychainService = "com.spooktacular.merkle-audit"

    /// Loads the SEP-bound P-256 signer for the given Keychain
    /// label, generating a fresh one on first use.
    ///
    /// The key is generated **inside** the Secure Enclave without
    /// a user-presence ACL — the daemon needs to sign tree heads
    /// continuously, so prompting per signature would be
    /// unworkable. Absence of `.userPresence` is not absence of
    /// hardware binding: the key bytes still never leave the SEP,
    /// they just don't require a live operator gesture to use.
    /// This matches how Apple Pay's device account numbers work
    /// for server-side settlement transactions.
    ///
    /// Keychain persistence:
    /// - Opaque SEP blob (`key.dataRepresentation`) is stored
    ///   under `merkleKeychainService` + `label` as a generic
    ///   password. The blob is only reconstructible on the SEP
    ///   that generated it — copy to another Mac and the key is
    ///   gone.
    /// - Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    ///   so the daemon can sign from launch at boot after the
    ///   first manual unlock of the host.
    public static func loadOrCreateSEPSigningKey(label: String) throws -> any P256Signer {
        guard !label.isEmpty else {
            throw AuditSinkFactoryError.merkleKeyLabelEmpty
        }

        // Try to load the existing blob.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: merkleKeychainService,
            kSecAttrAccount as String: label,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess {
            guard let data = item as? Data else {
                throw AuditSinkFactoryError.merkleKeyMalformed(label: label)
            }
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(
                    dataRepresentation: data
                )
                return SEPSigner(key)
            } catch {
                throw AuditSinkFactoryError.merkleKeyMalformed(label: label)
            }
        }
        if status != errSecItemNotFound {
            throw AuditSinkFactoryError.merkleKeychainFailure(status: status)
        }

        // First run — generate and persist.
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey()
        } catch {
            throw AuditSinkFactoryError.secureEnclaveUnavailable(underlying: error)
        }

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: merkleKeychainService,
            kSecAttrAccount as String: label,
            kSecValueData as String: key.dataRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrDescription as String: "Spooktacular Merkle audit SEP-bound P-256 key",
            kSecAttrLabel as String: "Spooktacular Merkle audit (\(label))"
        ]
        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AuditSinkFactoryError.merkleKeychainFailure(status: addStatus)
        }
        return SEPSigner(key)
    }

    // MARK: - Software signer (tests / non-SEP hosts)

    /// Loads a PEM-encoded P-256 signing key from disk, creating
    /// it on first run with restrictive permissions.
    ///
    /// File layout: PEM-encoded P-256 private key. On creation
    /// the file is written with mode 0600; if it already exists
    /// with weaker permissions the loader refuses to proceed.
    ///
    /// Not the production default — use ``loadOrCreateSEPSigningKey(label:)``
    /// when a Secure Enclave is available. This path exists for
    /// hosts without an SEP (bare-metal Linux controllers in
    /// non-Apple deployments) and for unit-test isolation.
    public static func loadOrCreateSoftwareSigningKey(at path: String) throws -> any P256Signer {
        let url = URL(filePath: path)
        let fm = FileManager.default

        if fm.fileExists(atPath: path) {
            let attrs = try fm.attributesOfItem(atPath: path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            guard mode & 0o077 == 0 else {
                throw AuditSinkFactoryError.merkleKeyPermissionsTooOpen(path: path, mode: mode)
            }
            let pem = try String(contentsOf: url, encoding: .utf8)
            return try P256.Signing.PrivateKey(pemRepresentation: pem)
        }

        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let newKey = P256.Signing.PrivateKey()

        // O_CREAT | O_EXCL | O_NOFOLLOW — atomic create at 0600
        // that refuses to traverse a symlink swap.
        try path.withCString { cPath in
            let fd = open(cPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else {
                throw AuditSinkFactoryError.merkleKeyCreateFailed(path: path, errno: errno)
            }
            defer { close(fd) }
            let data = Data(newKey.pemRepresentation.utf8)
            try data.withUnsafeBytes { buffer in
                var remaining = buffer.count
                var base = buffer.baseAddress
                while remaining > 0 {
                    let written = write(fd, base, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw AuditSinkFactoryError.merkleKeyCreateFailed(path: path, errno: errno)
                    }
                    remaining -= written
                    base = base?.advanced(by: written)
                }
            }
            fsync(fd)
        }
        return newKey
    }
}

// MARK: - Errors

/// Errors raised while composing an audit sink chain.
public enum AuditSinkFactoryError: Error, LocalizedError, Sendable {
    case merkleKeyRequired
    case merkleKeyAmbiguous
    case merkleKeyLabelEmpty
    case merkleKeyPermissionsTooOpen(path: String, mode: UInt16)
    case merkleKeyCreateFailed(path: String, errno: Int32)
    case merkleKeyMalformed(label: String)
    case merkleKeychainFailure(status: OSStatus)
    case secureEnclaveUnavailable(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .merkleKeyRequired:
            return "Merkle audit is enabled but neither SPOOK_AUDIT_SIGNING_KEY_LABEL (SEP-bound, recommended) nor SPOOK_AUDIT_SIGNING_KEY_PATH (software) is set. A persistent signing key is required so tree heads verify across restarts."
        case .merkleKeyAmbiguous:
            return "Both SPOOK_AUDIT_SIGNING_KEY_LABEL and SPOOK_AUDIT_SIGNING_KEY_PATH are set — choose exactly one. Prefer the label (Secure Enclave) in production."
        case .merkleKeyLabelEmpty:
            return "SPOOK_AUDIT_SIGNING_KEY_LABEL is set but empty."
        case .merkleKeyPermissionsTooOpen(let path, let mode):
            return String(
                format: "Merkle signing key at '%@' has permissions 0%o. Expected 0600 (owner-only). `chmod 600 %@` then retry.",
                path, mode, path
            )
        case .merkleKeyCreateFailed(let path, let err):
            let msg = String(cString: strerror(err))
            return "Failed to create Merkle signing key at '\(path)': \(msg) (errno \(err))."
        case .merkleKeyMalformed(let label):
            return "Keychain entry for Merkle signing key '\(label)' is not a valid Secure Enclave key blob. It may have been tampered with or generated on a different SEP."
        case .merkleKeychainFailure(let status):
            return "Keychain operation failed with OSStatus \(status) while loading the Merkle signing key."
        case .secureEnclaveUnavailable(let err):
            return "Secure Enclave unavailable on this host: \(err.localizedDescription). Use SPOOK_AUDIT_SIGNING_KEY_PATH (software fallback) on hosts without an SEP."
        }
    }
}

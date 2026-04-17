import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SpookApplication

/// Unified Secure-Enclave / software P-256 key-provisioning
/// primitive. The single source of truth for every SEP-bound
/// signing key Spooktacular manages:
///
/// | Service namespace                          | Purpose                            | Presence gate          |
/// |--------------------------------------------|------------------------------------|------------------------|
/// | `P256KeyStore.Service.breakGlass`          | Operator-minted break-glass tickets | `.userPresence`        |
/// | `P256KeyStore.Service.operatorIdentity`    | Operator signs API requests         | `.userPresence`        |
/// | `P256KeyStore.Service.hostIdentity`        | Host signs to guest agent           | none (daemon use)      |
/// | `P256KeyStore.Service.merkleAudit`         | STH signing for audit Merkle tree   | none (daemon use)      |
/// | `P256KeyStore.Service.oidcIssuer`          | Workload-identity JWT minting       | none (daemon use)      |
///
/// ## Why one store
///
/// Before this type, break-glass + Merkle audit + OIDC issuer
/// each had their own lookalike SEP-provisioning code —
/// different error taxonomies, slightly different Keychain
/// attributes, one file with both SEP and software paths
/// interleaved. The unified store gives every purpose the same
/// lifecycle (store / loadSigner / publicKey / delete / exists)
/// with per-purpose namespacing so inventory queries, rotation,
/// and audit are consistent.
///
/// ## SEP vs software
///
/// Production calls ``loadOrCreateSEP(service:label:accessControl:authenticationPrompt:)``.
/// Tests and non-SEP hosts (CI, older Intel Macs without T2,
/// hybrid deployments where the controller runs on non-Apple
/// hardware) call ``loadOrCreateSoftware(at:)`` with a PEM file
/// path at mode 0600.
public enum P256KeyStore {

    // MARK: - Service namespaces

    /// Well-known Keychain service strings, one per key purpose.
    /// Each purpose gets its own namespace so a review of
    /// `security find-generic-password -s com.spooktacular.X`
    /// enumerates exactly the keys for that purpose.
    public enum Service {
        /// Break-glass ticket signing (operator-initiated,
        /// user-presence gated).
        public static let breakGlass = "com.spooktacular.break-glass"

        /// Operator identity for signing HTTP API requests
        /// (operator-initiated, user-presence gated).
        public static let operatorIdentity = "com.spooktacular.operator-identity"

        /// Host identity for signing host → guest-agent
        /// requests (daemon use, no presence gate).
        public static let hostIdentity = "com.spooktacular.host-identity"

        /// Merkle audit STH signing (daemon use).
        public static let merkleAudit = "com.spooktacular.merkle-audit"

        /// Workload-identity OIDC JWT signing (daemon use).
        public static let oidcIssuer = "com.spooktacular.oidc-issuer"
    }

    // MARK: - SEP provisioning

    /// Generates a new SEP-bound P-256 key or loads the
    /// existing one for `(service, label)`. The returned signer
    /// is a ``SEPSigner`` whose `dataRepresentation` persisted
    /// in the Keychain is only reconstructible on the SEP that
    /// created it.
    ///
    /// - Parameters:
    ///   - service: Keychain service namespace. Use one of the
    ///     constants in ``Service``.
    ///   - label: Account label within the namespace, e.g.
    ///     `"alice-workstation"` or `"controller-prod-01"`.
    ///   - presenceGated: When `true`, the SEP refuses signing
    ///     without a live user gesture (Touch ID / passcode) at
    ///     use time. `false` is daemon use — the key stays
    ///     hardware-bound but signs autonomously.
    ///   - authenticationPrompt: User-facing reason shown in the
    ///     Touch ID sheet. Required when `presenceGated == true`;
    ///     ignored otherwise. Be specific: "Mint a break-glass
    ///     ticket for tenant acme" reads better than
    ///     "Authenticate".
    public static func loadOrCreateSEP(
        service: String,
        label: String,
        presenceGated: Bool = false,
        authenticationPrompt: String? = nil
    ) async throws -> any P256Signer {
        guard !label.isEmpty else { throw KeyStoreError.invalidLabel }
        if presenceGated && authenticationPrompt == nil {
            throw KeyStoreError.missingAuthenticationPrompt
        }

        // Pre-flight: Secure Enclave availability.
        //
        // CryptoKit exposes `SecureEnclave.isAvailable` exactly
        // for this — ask once before the `try
        // SecureEnclave.P256.Signing.PrivateKey(...)` call that
        // will otherwise throw a low-level error on Intel Macs
        // without T2, on non-Apple hosts, and in hybrid
        // deployments where the controller runs on non-Apple
        // hardware. Apple docs:
        // https://developer.apple.com/documentation/cryptokit/secureenclave
        //
        // The explicit `.secureEnclaveUnavailableOnHost` carries
        // a fallback pointer to `loadOrCreateSoftware(at:)` so
        // operators see the recovery path in the surfaced error
        // without reading the source.
        guard SecureEnclave.isAvailable else {
            throw KeyStoreError.secureEnclaveUnavailableOnHost
        }

        // Fast path — key already exists.
        if let existing = try await loadExisting(
            service: service, label: label,
            presenceGated: presenceGated,
            authenticationPrompt: authenticationPrompt
        ) {
            return existing
        }

        // First-use — generate inside the SEP.
        let key: SecureEnclave.P256.Signing.PrivateKey
        if presenceGated {
            var cfErr: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &cfErr
            ) else {
                throw KeyStoreError.accessControlFailed(
                    cfErr?.takeRetainedValue() as Error?
                )
            }
            do {
                key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            } catch {
                throw KeyStoreError.secureEnclaveUnavailable(underlying: error)
            }
        } else {
            do {
                key = try SecureEnclave.P256.Signing.PrivateKey()
            } catch {
                throw KeyStoreError.secureEnclaveUnavailable(underlying: error)
            }
        }

        let accessibility = presenceGated
            ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecValueData as String: key.dataRepresentation,
            kSecAttrAccessible as String: accessibility,
            kSecAttrDescription as String: "Spooktacular SEP-bound P-256 key (\(service))",
            kSecAttrLabel as String: "Spooktacular \(service) (\(label))"
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.keychainStatus(status, operation: "SecItemAdd")
        }

        // For presence-gated keys the caller needs a signer that
        // already consumed the prompt; reconstruct via the
        // `loadExisting` path so we get a live LAContext.
        if presenceGated {
            guard let signer = try await loadExisting(
                service: service, label: label,
                presenceGated: true,
                authenticationPrompt: authenticationPrompt
            ) else {
                throw KeyStoreError.malformedKeyData
            }
            return signer
        }
        return SEPSigner(key)
    }

    /// Retrieves the public key for `(service, label)` without
    /// prompting for presence. Use for distributing the public
    /// key into trust allowlists, never for signing.
    public static func publicKey(service: String, label: String) throws -> P256.Signing.PublicKey {
        guard !label.isEmpty else { throw KeyStoreError.invalidLabel }
        let blob = try loadBlob(service: service, label: label)
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
            return key.publicKey
        } catch {
            throw KeyStoreError.malformedKeyData
        }
    }

    /// Removes the key for `(service, label)`. Silent
    /// idempotent delete.
    public static func delete(service: String, label: String) throws {
        guard !label.isEmpty else { throw KeyStoreError.invalidLabel }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychainStatus(status, operation: "SecItemDelete")
        }
    }

    /// Non-prompting existence check.
    public static func exists(service: String, label: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // MARK: - Software fallback

    /// Loads an existing PEM-encoded P-256 key at `path`, or
    /// creates one with owner-only permissions on first use.
    ///
    /// Production deployments should prefer ``loadOrCreateSEP``
    /// whenever an SEP is available; software keys exist for
    /// CI, non-Apple hosts, and unit tests.
    public static func loadOrCreateSoftware(at path: String) throws -> any P256Signer {
        let url = URL(filePath: path)
        let fm = FileManager.default

        if fm.fileExists(atPath: path) {
            let attrs = try fm.attributesOfItem(atPath: path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            guard mode & 0o077 == 0 else {
                throw KeyStoreError.softwareKeyPermissionsTooOpen(path: path, mode: mode)
            }
            let pem = try String(contentsOf: url, encoding: .utf8)
            return try P256.Signing.PrivateKey(pemRepresentation: pem)
        }

        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let newKey = P256.Signing.PrivateKey()

        try path.withCString { cPath in
            let fd = open(cPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else {
                throw KeyStoreError.softwareKeyCreateFailed(path: path, errno: errno)
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
                        throw KeyStoreError.softwareKeyCreateFailed(path: path, errno: errno)
                    }
                    remaining -= written
                    base = base?.advanced(by: written)
                }
            }
            fsync(fd)
        }
        return newKey
    }

    // MARK: - Internals

    private static func loadExisting(
        service: String,
        label: String,
        presenceGated: Bool,
        authenticationPrompt: String?
    ) async throws -> (any P256Signer)? {
        guard exists(service: service, label: label) else { return nil }
        let blob = try loadBlob(service: service, label: label)

        if presenceGated {
            guard let reason = authenticationPrompt else {
                throw KeyStoreError.missingAuthenticationPrompt
            }
            let context = LAContext()
            context.localizedReason = reason
            do {
                let ok = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication, localizedReason: reason
                )
                guard ok else { throw KeyStoreError.userDeclined }
            } catch let err as LAError {
                switch err.code {
                case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled:
                    throw KeyStoreError.presenceUnavailable(underlying: err)
                default:
                    throw KeyStoreError.userDeclined
                }
            } catch {
                throw KeyStoreError.userDeclined
            }
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(
                    dataRepresentation: blob,
                    authenticationContext: context
                )
                return SEPSigner(key)
            } catch {
                throw KeyStoreError.malformedKeyData
            }
        }

        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
            return SEPSigner(key)
        } catch {
            throw KeyStoreError.malformedKeyData
        }
    }

    private static func loadBlob(service: String, label: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeyStoreError.keychainStatus(status, operation: "SecItemCopyMatching (unexpected type)")
            }
            return data
        case errSecItemNotFound:
            throw KeyStoreError.notFound(service: service, label: label)
        case errSecUserCanceled, errSecAuthFailed:
            throw KeyStoreError.userDeclined
        default:
            throw KeyStoreError.keychainStatus(status, operation: "SecItemCopyMatching")
        }
    }
}

// MARK: - Errors

/// Errors produced by ``P256KeyStore``.
public enum KeyStoreError: Error, LocalizedError {
    case invalidLabel
    case missingAuthenticationPrompt
    case accessControlFailed(Error?)
    case secureEnclaveUnavailable(underlying: Error)

    /// Pre-flight via `SecureEnclave.isAvailable` returned
    /// `false` — this host has no SEP (Intel Mac without T2,
    /// non-Apple hardware, or a stripped virtualized
    /// environment). Distinct from
    /// ``secureEnclaveUnavailable(underlying:)``, which reports
    /// a late failure during key creation. Points at
    /// ``P256KeyStore/loadOrCreateSoftware(at:)`` as the
    /// fallback.
    case secureEnclaveUnavailableOnHost

    case notFound(service: String, label: String)
    case userDeclined
    case presenceUnavailable(underlying: Error?)
    case malformedKeyData
    case keychainStatus(OSStatus, operation: String)
    case softwareKeyPermissionsTooOpen(path: String, mode: UInt16)
    case softwareKeyCreateFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidLabel:
            "Key label is empty."
        case .missingAuthenticationPrompt:
            "Presence-gated key access requires a user-facing prompt string."
        case .accessControlFailed(let err):
            "Could not create a Keychain access-control policy: \(err.map { $0.localizedDescription } ?? "unknown error")"
        case .secureEnclaveUnavailable(let err):
            "Secure Enclave unavailable on this host: \(err.localizedDescription)"
        case .secureEnclaveUnavailableOnHost:
            "This host has no Secure Enclave (SecureEnclave.isAvailable == false). Switch to `P256KeyStore.loadOrCreateSoftware(at:)` for Intel Macs without a T2 chip, CI, or non-Apple controller deployments."
        case .notFound(let service, let label):
            "No key exists under service '\(service)' label '\(label)'."
        case .userDeclined:
            "Key access was cancelled or failed presence verification."
        case .presenceUnavailable:
            "This host cannot verify user presence: no Touch ID, Watch, or login password configured."
        case .malformedKeyData:
            "The data stored in the Keychain is not a valid Secure Enclave key representation."
        case .keychainStatus(let status, let op):
            "Keychain \(op) failed with OSStatus \(status)."
        case .softwareKeyPermissionsTooOpen(let path, let mode):
            String(
                format: "Software key at '%@' has permissions 0%o. Expected 0600 (owner-only). `chmod 600 %@` then retry.",
                path, mode, path
            )
        case .softwareKeyCreateFailed(let path, let err):
            "Failed to create software key at '\(path)': \(String(cString: strerror(err))) (errno \(err))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidLabel:
            "Supply a non-empty label (for example, 'alice-mbp' or 'controller-prod-01')."
        case .missingAuthenticationPrompt:
            "Pass `authenticationPrompt: \"...\"` describing the action requiring presence."
        case .accessControlFailed:
            "Ensure the device has Touch ID, Watch unlock, or a login password configured. SEP keys with `.userPresence` require at least one of these."
        case .secureEnclaveUnavailable:
            "This host lacks a Secure Enclave (Apple Silicon or Intel Mac with T2). Use the software-key fallback path."
        case .secureEnclaveUnavailableOnHost:
            "Use `P256KeyStore.loadOrCreateSoftware(at: \"<path-to-pem>\")` on this host. Software keys rely on filesystem-level protection (0600) rather than hardware isolation — adequate for CI and development, not for production key material that requires hardware-bound non-extractability."
        case .notFound:
            "Generate the key with the appropriate CLI (e.g. `spook break-glass keygen --keychain-label <label>`)."
        case .userDeclined:
            "Touch the sensor or enter the password when prompted. For unattended / CI environments use the software-key fallback path instead."
        case .presenceUnavailable:
            "Configure a login password on the host. For truly headless deployments, use a file-backed software-P-256 key."
        case .malformedKeyData:
            "The Keychain item was written by a different SEP or has been tampered with. Delete it and rotate."
        case .keychainStatus:
            "Inspect the OSStatus via `security error <status>` on the command line."
        case .softwareKeyPermissionsTooOpen:
            "Narrow the file's permissions with `chmod 600 <path>` and retry."
        case .softwareKeyCreateFailed:
            "Check the directory exists and is writable by the current user."
        }
    }
}

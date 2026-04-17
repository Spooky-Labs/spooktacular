import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Manages break-glass signing keys bound to the macOS Secure
/// Enclave.
///
/// ## Why Secure Enclave
///
/// Keys generated via `SecureEnclave.P256.Signing.PrivateKey`
/// live **inside the Secure Enclave Processor (SEP)** — a
/// separate die with its own ROM, RAM, and AES engine, isolated
/// from the AP (application processor) by hardware-enforced
/// boundaries. The private-key bytes never enter the AP's
/// address space: the caller hands the SEP a payload to sign,
/// the SEP performs the P-256 ECDSA operation inside its secure
/// domain, and returns only the signature. Full kernel
/// compromise, DMA attacks, and process-memory inspection all
/// come up empty.
///
/// The access-control policy we attach — `.userPresence` — means
/// the SEP additionally refuses the signing operation without a
/// live user gesture (Touch ID, Watch unlock, or device passcode)
/// at the moment of use. This is the same primitive that gates
/// Apple Pay and WebAuthn on macOS: AAL3 per NIST SP 800-63B.
///
/// ## Per-operator keys
///
/// Unlike file-backed keys, SEP-bound keys are **non-exportable**
/// — they can never leave the SEP that created them. This is a
/// security property, not a limitation. The recommended
/// operational model: each operator runs `spook break-glass
/// keygen --keychain-label <their-label>` on their own
/// workstation; the resulting public key is added to the fleet's
/// trust allowlist (`SPOOK_BREAKGLASS_PUBLIC_KEYS_DIR` on each
/// agent). Onboarding a new operator is a `.pem` drop; offboarding
/// is a `.pem` delete. Cryptographic attribution: the ticket's
/// signature cryptographically proves which operator's SEP
/// produced it, so audit non-repudiation actually works.
public enum BreakGlassSigningKeyStore {

    /// Keychain attribute service tag. Namespaces break-glass items
    /// under a predictable service so a reviewer can enumerate
    /// every break-glass key on a host with a single query.
    public static let service = "com.spooktacular.break-glass"

    // MARK: - Public API

    /// Generates a fresh P-256 signing key inside the Secure
    /// Enclave and persists its opaque `dataRepresentation` in
    /// the Keychain under `label`.
    ///
    /// Returns the matching public key for the caller to export
    /// (typically as PEM to a file for distribution to the
    /// fleet's agents).
    ///
    /// Throws ``BreakGlassSigningKeyStoreError/alreadyExists`` if
    /// an item with that label is already present — refusing to
    /// overwrite makes rotation an explicit ceremony.
    @discardableResult
    public static func store(label: String) throws -> P256.Signing.PublicKey {
        guard !label.isEmpty else {
            throw BreakGlassSigningKeyStoreError.invalidLabel
        }
        if exists(label: label) {
            throw BreakGlassSigningKeyStoreError.alreadyExists(label: label)
        }

        // `.userPresence` — biometry OR passcode, refreshed per
        // signing operation. Scoped to "when unlocked, this
        // device only" so the item cannot sync via iCloud
        // Keychain. (Not that SEP blobs are portable anyway,
        // but belt-and-braces with the accessibility attribute.)
        var cfErr: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &cfErr
        ) else {
            throw BreakGlassSigningKeyStoreError.accessControlFailed(
                cfErr?.takeRetainedValue() as Error?
            )
        }

        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        } catch {
            throw BreakGlassSigningKeyStoreError.secureEnclaveUnavailable(underlying: error)
        }

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecValueData as String: key.dataRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrDescription as String: "Spooktacular break-glass SEP-bound P-256 key",
            kSecAttrLabel as String: "Spooktacular break-glass (\(label))"
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BreakGlassSigningKeyStoreError.keychainStatus(
                status, operation: "SecItemAdd"
            )
        }
        return key.publicKey
    }

    /// Retrieves the SEP-bound signing key for `label`,
    /// pre-authenticating via LocalAuthentication so the SEP
    /// accepts subsequent `.signature(for:)` calls without
    /// prompting a second time.
    ///
    /// - Parameters:
    ///   - label: The label the key was stored under.
    ///   - reason: User-facing string shown in the Touch ID sheet.
    public static func loadSigner(
        label: String,
        reason: String
    ) async throws -> any BreakGlassSigner {
        guard !label.isEmpty else {
            throw BreakGlassSigningKeyStoreError.invalidLabel
        }

        let blob = try loadBlob(label: label)

        // Pre-authenticate the LAContext so the SEP key's
        // `.signature(for:)` call does not prompt a second time.
        let context = LAContext()
        context.localizedReason = reason
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason
            )
            guard ok else {
                throw BreakGlassSigningKeyStoreError.userDeclined
            }
        } catch let err as LAError {
            switch err.code {
            case .userCancel, .authenticationFailed, .userFallback, .appCancel, .systemCancel:
                throw BreakGlassSigningKeyStoreError.userDeclined
            case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled:
                throw BreakGlassSigningKeyStoreError.presenceUnavailable(underlying: err)
            default:
                throw BreakGlassSigningKeyStoreError.userDeclined
            }
        } catch {
            throw BreakGlassSigningKeyStoreError.userDeclined
        }

        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: blob,
                authenticationContext: context
            )
            return SEPSigner(key)
        } catch {
            throw BreakGlassSigningKeyStoreError.malformedKeyData
        }
    }

    /// Retrieves just the public key for `label` without
    /// prompting for presence. Useful for printing the fleet's
    /// trusted key ("which key am I about to distribute?").
    public static func publicKey(label: String) throws -> P256.Signing.PublicKey {
        guard !label.isEmpty else {
            throw BreakGlassSigningKeyStoreError.invalidLabel
        }
        let blob = try loadBlob(label: label)
        // Reconstructing the key without `authenticationContext`
        // means `.signature(...)` would trigger a prompt, but
        // `.publicKey` is a pure derivation that doesn't touch
        // the SEP secret — no prompt is emitted.
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: blob
            )
            return key.publicKey
        } catch {
            throw BreakGlassSigningKeyStoreError.malformedKeyData
        }
    }

    /// Removes the key for `label`. Silent idempotent delete.
    public static func delete(label: String) throws {
        guard !label.isEmpty else {
            throw BreakGlassSigningKeyStoreError.invalidLabel
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BreakGlassSigningKeyStoreError.keychainStatus(
                status, operation: "SecItemDelete"
            )
        }
    }

    /// Non-prompting existence check.
    public static func exists(label: String) -> Bool {
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

    // MARK: - Internals

    private static func loadBlob(label: String) throws -> Data {
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
                throw BreakGlassSigningKeyStoreError.keychainStatus(
                    status, operation: "SecItemCopyMatching (unexpected type)"
                )
            }
            return data
        case errSecItemNotFound:
            throw BreakGlassSigningKeyStoreError.notFound(label: label)
        case errSecUserCanceled, errSecAuthFailed:
            throw BreakGlassSigningKeyStoreError.userDeclined
        default:
            throw BreakGlassSigningKeyStoreError.keychainStatus(
                status, operation: "SecItemCopyMatching"
            )
        }
    }
}

// MARK: - Errors

/// Errors produced by ``BreakGlassSigningKeyStore``.
public enum BreakGlassSigningKeyStoreError: Error, LocalizedError {

    /// The supplied label was empty or otherwise invalid.
    case invalidLabel

    /// `SecAccessControlCreateWithFlags` failed. Usually indicates
    /// the device has no biometry or passcode configured.
    case accessControlFailed(Error?)

    /// This host lacks a Secure Enclave, or the SEP refused the
    /// generation request. Most commonly means an Intel Mac
    /// without a T2, or a SEP in a failed state.
    case secureEnclaveUnavailable(underlying: Error)

    /// A Keychain item with this label already exists.
    case alreadyExists(label: String)

    /// No Keychain item exists for this label.
    case notFound(label: String)

    /// The user cancelled or failed the presence prompt.
    case userDeclined

    /// The host cannot evaluate a presence policy — no biometry,
    /// no passcode, no paired watch.
    case presenceUnavailable(underlying: Error?)

    /// Keychain returned data that isn't a valid SEP key blob.
    case malformedKeyData

    /// A Keychain operation returned a non-success `OSStatus`.
    case keychainStatus(OSStatus, operation: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLabel:
            "Break-glass key label is empty."
        case .accessControlFailed(let err):
            "Could not create a Keychain access-control policy: \(err.map { $0.localizedDescription } ?? "unknown error")"
        case .secureEnclaveUnavailable(let err):
            "Secure Enclave unavailable on this host: \(err.localizedDescription)"
        case .alreadyExists(let label):
            "A break-glass key already exists under label '\(label)'."
        case .notFound(let label):
            "No break-glass key exists under label '\(label)'."
        case .userDeclined:
            "Break-glass key access was cancelled or failed presence verification."
        case .presenceUnavailable:
            "This host cannot verify user presence: no Touch ID, Watch, or login password is configured."
        case .malformedKeyData:
            "The data stored in the Keychain is not a valid Secure Enclave key representation."
        case .keychainStatus(let status, let op):
            "Keychain \(op) failed with OSStatus \(status)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidLabel:
            "Supply a non-empty label (for example, 'alice-mbp' or 'bob-workstation-2026')."
        case .accessControlFailed:
            "Ensure the device has Touch ID, Watch unlock, or a login password configured. SEP keys with `.userPresence` require at least one of these."
        case .secureEnclaveUnavailable:
            "Break-glass minting requires a Secure Enclave (Apple Silicon, or Intel Mac with T2). On hosts without an SEP, use the legacy software-keyed mode: `spook break-glass keygen --private-key <path>`."
        case .alreadyExists:
            "Delete the existing item with `spook break-glass rotate --keychain-label <label>` before issuing a new key under the same label."
        case .notFound:
            "Generate the key with `spook break-glass keygen --keychain-label <label>` or re-point to the correct label."
        case .userDeclined:
            "Touch the sensor or enter the password when prompted. For headless / CI environments use `--private-key <path>` (file-backed mode) instead."
        case .presenceUnavailable:
            "Configure a login password on the host. For truly headless deployments (CI pipelines), use `--private-key <path>` with a file-backed software-P-256 key — the `.userPresence` path requires biometry / passcode."
        case .malformedKeyData:
            "The Keychain item has been tampered with or was written by a different SEP. Delete it and rotate."
        case .keychainStatus:
            "Inspect the OSStatus via `security error <status>` on the command line."
        }
    }
}

import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Stores and retrieves the break-glass signing key in the macOS
/// Keychain with a `SecAccessControl` that requires user presence
/// (Touch ID, Watch unlock, or device passcode) at the moment of
/// retrieval.
///
/// ## Why Keychain + `.userPresence`
///
/// The file-at-0600 mode shipped in earlier releases (see
/// `AuditSinkFactory.loadOrCreateSigningKey`) protects against a
/// different local user reading the key but does not protect
/// against a malicious process running as the same user. Persistent
/// malware, a compromised SSH session, or a cached shell with an
/// operator's credentials can read the file without any prompt.
///
/// A Keychain item guarded by ``LAPolicy/deviceOwnerAuthenticationWithBiometrics``
/// via `SecAccessControl` moves the trust boundary out of the
/// calling process and into the Secure Enclave + LocalAuthentication
/// TCB: the key bytes are not released unless a living user consents
/// at retrieval time. This is the Apple-native analog of the
/// "per-action MFA" pattern OWASP ASVS V2.7 calls for.
///
/// > Important: Ed25519 / `Curve25519.Signing.PrivateKey` is a
/// > software key on macOS — CryptoKit does not route Ed25519 through
/// > the Secure Enclave (the SEP's asymmetric ops are P-256 only).
/// > The `.userPresence` gate therefore protects *retrieval*; the
/// > signing operation that follows happens in the calling process.
/// > For a fully hardware-bound signer the caller would have to
/// > switch to `SecureEnclave.P256.Signing.PrivateKey`, which
/// > changes the wire format and every downstream verifier — out of
/// > scope for this release. Retrieval-level protection is still
/// > materially stronger than file-at-0600.
public enum BreakGlassSigningKeyStore {

    /// Keychain attribute service tag. Namespaces break-glass items
    /// under a predictable service so a reviewer can enumerate
    /// exactly how many break-glass keys exist on a host.
    public static let service = "com.spooktacular.break-glass"

    // MARK: - Public API

    /// Stores a freshly generated Ed25519 private key in the
    /// Keychain under `label`, with a `SecAccessControl` policy
    /// that requires user presence at retrieval.
    ///
    /// Throws ``BreakGlassSigningKeyStoreError/alreadyExists`` if a
    /// key with that label is already present — we refuse to
    /// overwrite so a rotation ceremony is explicit.
    public static func store(
        _ key: Curve25519.Signing.PrivateKey,
        label: String
    ) throws {
        guard !label.isEmpty else {
            throw BreakGlassSigningKeyStoreError.invalidLabel
        }

        // A `SecAccessControl` combining "must have a credential
        // stored on the device" (which `.userPresence` expands to)
        // with the "when unlocked this device only" accessibility.
        // The last part prevents the item from syncing to other
        // devices via iCloud Keychain — break-glass keys are
        // per-host artifacts.
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

        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessControl as String: access,
            kSecAttrDescription as String: "Spooktacular break-glass Ed25519 signing key",
            kSecAttrLabel as String: "Spooktacular break-glass (\(label))"
        ]
        // Refuse to store over an existing item — rotation must be
        // explicit. Using `SecItemCopyMatching` is cheaper than
        // `SecItemAdd` + handling `errSecDuplicateItem`.
        if exists(label: label) {
            throw BreakGlassSigningKeyStoreError.alreadyExists(label: label)
        }
        _ = attrs.removeValue(forKey: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BreakGlassSigningKeyStoreError.keychainStatus(
                status,
                operation: "SecItemAdd"
            )
        }
    }

    /// Loads the break-glass signing key for `label`.
    ///
    /// This call triggers a `LocalAuthentication` prompt (Touch ID
    /// or passcode). The returned key is live in memory only for
    /// as long as the caller retains it; it is not cached anywhere.
    ///
    /// - Parameters:
    ///   - label: The label the key was stored under.
    ///   - reason: User-facing string shown in the Touch ID sheet.
    ///     Be specific — "Mint a break-glass ticket for tenant acme"
    ///     reads better than "Authenticate".
    public static func load(
        label: String,
        reason: String
    ) throws -> Curve25519.Signing.PrivateKey {
        guard !label.isEmpty else {
            throw BreakGlassSigningKeyStoreError.invalidLabel
        }

        // Pre-authenticate via LAContext so the Keychain query can
        // reuse the evaluation instead of prompting a second time.
        let context = LAContext()
        context.localizedReason = reason

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseOperationPrompt as String: reason
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
            do {
                return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            } catch {
                throw BreakGlassSigningKeyStoreError.malformedKeyData
            }
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

    /// Removes the key for `label`. Succeeds silently if no such
    /// item exists — idempotent delete is the right UX for a
    /// rotation script.
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

    /// Non-prompting existence check. Uses `kSecReturnAttributes`
    /// without `kSecReturnData` so the query succeeds without
    /// triggering the user-presence gate.
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
        // `errSecInteractionNotAllowed` means "the item exists but
        // we'd have to prompt to return its data" — treat as exists.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
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

    /// A Keychain item with this label already exists — rotation
    /// must be explicit.
    case alreadyExists(label: String)

    /// No Keychain item exists for this label.
    case notFound(label: String)

    /// The user cancelled or failed the presence prompt.
    case userDeclined

    /// Keychain returned data that isn't a valid Ed25519 raw key.
    case malformedKeyData

    /// A Keychain operation returned a non-success `OSStatus`.
    case keychainStatus(OSStatus, operation: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLabel:
            "Break-glass key label is empty."
        case .accessControlFailed(let err):
            "Could not create a Keychain access-control policy: \(err.map { $0.localizedDescription } ?? "unknown error")"
        case .alreadyExists(let label):
            "A break-glass key already exists under label '\(label)'."
        case .notFound(let label):
            "No break-glass key exists under label '\(label)'."
        case .userDeclined:
            "Break-glass key access was cancelled or failed presence verification."
        case .malformedKeyData:
            "The data stored in the Keychain is not a valid 32-byte Ed25519 key."
        case .keychainStatus(let status, let op):
            "Keychain \(op) failed with OSStatus \(status)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidLabel:
            "Supply a non-empty label (for example, 'fleet-default' or 'team-a-q2-2026')."
        case .accessControlFailed:
            "Ensure the device has Touch ID, Watch unlock, or a login password configured. Break-glass with `.userPresence` requires at least one of these."
        case .alreadyExists:
            "Delete the existing item with `spook break-glass rotate --keychain-label <label>` before issuing a new key under the same label."
        case .notFound:
            "Generate the key with `spook break-glass keygen --keychain-label <label>` or re-point to the correct label."
        case .userDeclined:
            "Touch the sensor or enter the password when prompted. For unattended / CI environments use `--private-key <path>` (file-backed mode) instead."
        case .malformedKeyData:
            "The Keychain item has been tampered with. Delete it and rotate the key."
        case .keychainStatus:
            "Inspect the OSStatus via `security error <status>` on the command line."
        }
    }
}

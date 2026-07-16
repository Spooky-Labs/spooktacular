import Foundation
import Security

/// Transient store for a VM's first-boot account password in the macOS
/// **login Keychain**.
///
/// This is the secret half of the native-provisioning design. The
/// non-secret fields (username, full name, setup preferences) live in
/// `metadata.json` as a ``SpooktacularCore/PendingProvisioning`` marker;
/// the account **password never touches disk in plaintext**. It is held
/// only here — a generic-password Keychain item under service
/// ``service``, keyed by the VM's UUID — for exactly the window between
/// `create` and the first successful `start`:
///
/// 1. `spook create` generates (or accepts) the password and calls
///    ``store(password:forVM:)``.
/// 2. The first `spook start` calls ``readPassword(forVM:)``, applies
///    the spec via `VZMacGuestProvisioningOptions`, then calls
///    ``deletePassword(forVM:)`` — the password exists nowhere after
///    the first boot.
///
/// ## Accessibility
///
/// Items are written with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, mirroring
/// ``KeychainTLSProvider``'s private-key handling: the CLI must read the
/// password back on a headless first boot (no live user gesture), so a
/// `WhenUnlocked` gate is too strict, and `ThisDeviceOnly` keeps the
/// secret off iCloud Keychain.
///
/// ## Sandboxing note
///
/// The `Spooktacular.app` GUI is sandboxed and, absent a shared
/// keychain-access-group entitlement (which we intentionally do not
/// add), cannot read a login-Keychain item written by the non-sandboxed
/// CLI. ``readPassword(forVM:)`` returns `nil` (or throws) in that case;
/// the GUI treats a missing password as "provisioning deferred to the
/// CLI" rather than a failure. See `AppState.startVM`.
public enum ProvisioningPasswordStore {

    /// Keychain service name for transient first-boot passwords.
    /// Follows the same `com.spooktacular.*` convention as
    /// ``GitHubKeychain`` and ``P256KeyStore/Service``.
    public static let service = "com.spooktacular.provisioning"

    /// Stores `password` for the VM identified by `id`, replacing any
    /// existing item for that VM.
    ///
    /// - Parameters:
    ///   - password: The account password to hold until first boot.
    ///     Must be non-empty.
    ///   - id: The VM's stable UUID (the Keychain account key).
    /// - Throws: ``ProvisioningPasswordStoreError/emptyPassword`` when
    ///   `password` is empty, or
    ///   ``ProvisioningPasswordStoreError/keychainStatus(_:operation:)``
    ///   when the Keychain rejects the write.
    public static func store(password: String, forVM id: UUID) throws {
        guard !password.isEmpty else {
            throw ProvisioningPasswordStoreError.emptyPassword
        }
        // Delete-then-add keeps the item single-valued: a re-`create`
        // that reuses a UUID (or a retried create) overwrites cleanly
        // instead of failing with errSecDuplicateItem.
        try deletePassword(forVM: id)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrDescription as String: "Spooktacular first-boot provisioning password",
            kSecAttrLabel as String: "Spooktacular provisioning (\(id.uuidString))",
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProvisioningPasswordStoreError.keychainStatus(status, operation: "SecItemAdd")
        }
    }

    /// Reads the stored password for the VM identified by `id`.
    ///
    /// - Parameter id: The VM's stable UUID.
    /// - Returns: The password, or `nil` when no item exists for `id`
    ///   (never created, already consumed, or unreadable from this
    ///   process's Keychain domain — e.g. the sandboxed GUI).
    /// - Throws: ``ProvisioningPasswordStoreError/malformedData`` when
    ///   the stored bytes are not valid UTF-8, or
    ///   ``ProvisioningPasswordStoreError/keychainStatus(_:operation:)``
    ///   on any non-`errSecItemNotFound` failure.
    public static func readPassword(forVM id: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw ProvisioningPasswordStoreError.keychainStatus(
                    status, operation: "SecItemCopyMatching (unexpected type)"
                )
            }
            guard let password = String(data: data, encoding: .utf8) else {
                throw ProvisioningPasswordStoreError.malformedData
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw ProvisioningPasswordStoreError.keychainStatus(
                status, operation: "SecItemCopyMatching"
            )
        }
    }

    /// Removes the stored password for the VM identified by `id`.
    ///
    /// Idempotent: a missing item is treated as success, so this is
    /// safe to call after a successful first boot regardless of whether
    /// the item was ever written.
    ///
    /// - Parameter id: The VM's stable UUID.
    /// - Throws:
    ///   ``ProvisioningPasswordStoreError/keychainStatus(_:operation:)``
    ///   on a delete failure other than `errSecItemNotFound`.
    public static func deletePassword(forVM id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProvisioningPasswordStoreError.keychainStatus(status, operation: "SecItemDelete")
        }
    }
}

// MARK: - Errors

/// Failures raised by ``ProvisioningPasswordStore``.
public enum ProvisioningPasswordStoreError: Error, LocalizedError, Equatable {

    /// A password of length zero was passed to
    /// ``ProvisioningPasswordStore/store(password:forVM:)``.
    case emptyPassword

    /// The Keychain item's data was not valid UTF-8.
    case malformedData

    /// A `SecItem*` call returned a non-success `OSStatus`.
    case keychainStatus(OSStatus, operation: String)

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            "Refusing to store an empty first-boot provisioning password."
        case .malformedData:
            "The stored provisioning password is not valid UTF-8."
        case .keychainStatus(let status, let operation):
            "Keychain \(operation) failed with OSStatus \(status)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .emptyPassword:
            "Supply a non-empty --vm-password, or omit it to have one generated."
        case .malformedData:
            "Delete the Keychain item and recreate the VM: "
            + "`security delete-generic-password -s com.spooktacular.provisioning`."
        case .keychainStatus:
            "Inspect the OSStatus via `security error <status>` on the command line."
        }
    }
}

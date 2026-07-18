import Foundation
import Security

/// Transient store for a VM's first-boot account password in the macOS
/// **System keychain** (`/Library/Keychains/System.keychain`).
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
/// ## Why the System keychain (not login)
///
/// The `--remote-desktop` / `--openclaw` / `--user-data` flows inject a
/// provisioner into the guest disk, which requires **root** — so
/// `spook create` runs under `sudo` (or the EC2 Mac root service). A
/// secret written to the *login* keychain under `sudo` lands in root's
/// login-keychain domain, which is unavailable in a non-interactive root
/// context and unreadable by a later non-root `start` — the same reason
/// the GitHub runner PAT lives in the System keychain ("root can't read
/// the login keychain"). The System keychain is root-writable, shared
/// across login sessions, and ACL-controllable, so a `sudo spook create`
/// write is readable by a `sudo spook start`.
///
/// Consequence: **both `create` and `start` must run as root** for the
/// account to be provisioned. A non-root `start` (or the sandboxed GUI)
/// can't read the item; ``readPassword(forVM:)`` returns `nil` and the
/// caller boots without provisioning — see `AppState.startVM` and
/// `Start.swift`, which surface a "run under sudo" hint rather than fail.
///
/// ## Accessibility
///
/// Items are written with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, mirroring
/// ``KeychainTLSProvider``'s private-key handling: the CLI must read the
/// password back on a headless first boot (no live user gesture), so a
/// `WhenUnlocked` gate is too strict, and `ThisDeviceOnly` keeps the
/// secret off iCloud Keychain.
public enum ProvisioningPasswordStore {

    /// Keychain service name for transient first-boot passwords.
    /// Follows the same `com.spooktacular.*` convention as
    /// ``GitHubKeychain`` and ``P256KeyStore/Service``.
    public static let service = "com.spooktacular.provisioning"

    // MARK: - Public API (System keychain)

    /// Stores `password` for the VM identified by `id`, replacing any
    /// existing item for that VM. Requires root (writes the System
    /// keychain).
    ///
    /// - Throws: ``ProvisioningPasswordStoreError/emptyPassword`` when
    ///   `password` is empty, or
    ///   ``ProvisioningPasswordStoreError/keychainStatus(_:operation:)``
    ///   when the Keychain rejects the write (e.g. `errSecAuthFailed`
    ///   when not run as root).
    public static func store(password: String, forVM id: UUID) throws {
        try store(password: password, forVM: id, in: .system)
    }

    /// Reads the stored password for the VM identified by `id`.
    ///
    /// - Returns: The password, or `nil` when no item exists for `id`
    ///   (never created, already consumed, or unreadable from this
    ///   process's Keychain domain — e.g. a non-root `start` or the
    ///   sandboxed GUI, neither of which can read the System keychain).
    public static func readPassword(forVM id: UUID) throws -> String? {
        try readPassword(forVM: id, in: .system)
    }

    /// Removes the stored password for the VM identified by `id`.
    /// Idempotent: a missing item is treated as success.
    public static func deletePassword(forVM id: UUID) throws {
        try deletePassword(forVM: id, in: .system)
    }

    // MARK: - Keychain target (a testable seam)

    /// Which keychain an operation runs against.
    enum Target {
        /// `/Library/Keychains/System.keychain` — the production target
        /// (root-writable, session-independent). See the type doc.
        case system
        /// The process's default (login) keychain — no root required.
        /// Used **only** by unit tests so the store/read/delete
        /// round-trip runs under `swift test`; the System-keychain path
        /// is exercised by the on-hardware `--remote-desktop` smoke test.
        case login
    }

    /// SecItem query additions that scope a *write* to `target`.
    private static func addScope(_ target: Target) throws -> [String: Any] {
        switch target {
        case .login:  return [:]
        case .system: return [kSecUseKeychain as String: try systemKeychain()]
        }
    }

    /// SecItem query additions that scope a *search / delete* to `target`.
    private static func searchScope(_ target: Target) throws -> [String: Any] {
        switch target {
        case .login:  return [:]
        case .system: return [kSecMatchSearchList as String: [try systemKeychain()] as CFArray]
        }
    }

    /// Opens a reference to the System keychain.
    ///
    /// `SecKeychainOpen` / `kSecUseKeychain` / `kSecMatchSearchList` are
    /// deprecated, but they are the only API that targets a specific
    /// file-based keychain — the data-protection keychain has no
    /// System-domain equivalent, and shelling out to `security(1)` would
    /// leak the password through `argv`. Opening only builds a ref (it
    /// does not verify the file or require privileges); a permissions
    /// error surfaces later, at the `SecItemAdd`.
    private static func systemKeychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
        guard status == errSecSuccess, let keychain else {
            throw ProvisioningPasswordStoreError.keychainStatus(status, operation: "SecKeychainOpen(System)")
        }
        return keychain
    }

    // MARK: - Implementation

    static func store(password: String, forVM id: UUID, in target: Target) throws {
        guard !password.isEmpty else {
            throw ProvisioningPasswordStoreError.emptyPassword
        }
        // Delete-then-add keeps the item single-valued: a re-`create`
        // that reuses a UUID (or a retried create) overwrites cleanly
        // instead of failing with errSecDuplicateItem.
        try deletePassword(forVM: id, in: target)

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrDescription as String: "Spooktacular first-boot provisioning password",
            kSecAttrLabel as String: "Spooktacular provisioning (\(id.uuidString))",
        ]
        attributes.merge(try addScope(target)) { _, new in new }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProvisioningPasswordStoreError.keychainStatus(status, operation: "SecItemAdd")
        }
    }

    static func readPassword(forVM id: UUID, in target: Target) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query.merge(try searchScope(target)) { _, new in new }
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

    static func deletePassword(forVM id: UUID, in target: Target) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        query.merge(try searchScope(target)) { _, new in new }
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

    /// A `SecItem*` / `SecKeychain*` call returned a non-success `OSStatus`.
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
            "Delete the item and recreate the VM: `sudo security "
            + "delete-generic-password -s com.spooktacular.provisioning "
            + "/Library/Keychains/System.keychain`."
        case .keychainStatus:
            "Run `spook create`/`spook start` under sudo (the provisioning "
            + "password lives in the root-owned System keychain), and inspect "
            + "the OSStatus via `security error <status>`."
        }
    }
}

import Foundation
import SpookCore
import SpookApplication
import Security

/// Stores secrets in the macOS Keychain via `Security.framework`.
///
/// Each secret is a generic password item keyed by a `(service, account)`
/// pair where `service` identifies the application and `account` identifies
/// the individual secret.
///
/// Items use ``kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`` so they
/// survive reboots but never migrate to other devices via Keychain sync.
///
/// ## Usage
///
/// ```swift
/// let store = KeychainSecretStore()
/// try store.store(key: "api-token", value: "abc123")
/// let token = try store.retrieve(key: "api-token") // "abc123"
/// try store.delete(key: "api-token")
/// ```
public struct KeychainSecretStore: SecretStore {

    // MARK: - Error

    /// Errors produced by Keychain operations.
    public enum KeychainError: Error, CustomStringConvertible {
        /// A Keychain API call returned a non-success `OSStatus`.
        case unhandledStatus(OSStatus)

        public var description: String {
            switch self {
            case .unhandledStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    // MARK: - Properties

    /// The Keychain service name that groups all secrets for this app.
    private let service: String

    // MARK: - Init

    /// Creates a store that uses the given Keychain service name.
    ///
    /// - Parameter service: A reverse-DNS identifier for the service.
    ///   Defaults to `"com.spooktacular"`.
    public init(service: String = "com.spooktacular") {
        self.service = service
    }

    // MARK: - SecretStore

    public func store(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unhandledStatus(errSecParam)
        }

        // Remove any existing item first so the add always succeeds.
        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    public func retrieve(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unhandledStatus(errSecDecode)
            }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }
}

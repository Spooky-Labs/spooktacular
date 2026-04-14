import Foundation

/// Abstracts secure secret storage so use cases never depend on
/// a specific backend (Keychain, encrypted file, vault service, etc.).
///
/// The Infrastructure layer provides ``KeychainSecretStore`` for
/// macOS Keychain via `Security.framework`. Tests can inject an
/// in-memory store.
///
/// ## Clean Architecture
///
/// Secret storage is an infrastructure concern. Use cases that need
/// credentials — API tokens, webhook secrets, TLS passphrases — call
/// through this protocol without knowing *where* or *how* the secret
/// is persisted.
public protocol SecretStore: Sendable {
    /// Persists a secret under the given key, replacing any existing value.
    ///
    /// - Parameters:
    ///   - key: A unique identifier for the secret (e.g. `"api-token"`).
    ///   - value: The plaintext secret value.
    /// - Throws: If the underlying store rejects the write.
    func store(key: String, value: String) throws

    /// Retrieves the secret for the given key, or `nil` if none exists.
    ///
    /// - Parameter key: The identifier used when the secret was stored.
    /// - Returns: The plaintext secret, or `nil` if not found.
    /// - Throws: If the underlying store cannot be queried.
    func retrieve(key: String) throws -> String?

    /// Deletes the secret for the given key. No-op if the key doesn't exist.
    ///
    /// - Parameter key: The identifier of the secret to remove.
    /// - Throws: If the underlying store rejects the deletion.
    func delete(key: String) throws
}

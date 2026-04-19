import Foundation
import Security

/// Resolves the GitHub webhook HMAC-SHA-256 shared secret from the
/// **macOS Keychain only**.
///
/// Mirrors ``GitHubTokenResolver`` — same reference-architecture
/// stance: env-var and file-on-disk resolution paths were
/// excluded intentionally because they're readable by malware
/// running as the logged-in user. The Keychain, backed by
/// `SecItemCopyMatching`, requires an unlocked Keychain bound to
/// this device (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
/// so sibling processes can't exfiltrate the HMAC key from `ps`,
/// `launchctl print`, or `/etc/**`.
///
/// Each controller instance resolves one secret per webhook-source
/// account (`github-webhook-org-acme`, `github-webhook-personal`,
/// etc.), mirroring the per-account pattern GitHub token
/// resolution uses.
///
/// ## Populating the Keychain
///
/// One-time setup per host, per account:
///
/// ```bash
/// security add-generic-password \
///     -s com.spooktacular.webhook \
///     -a <account-name> \
///     -w "$(openssl rand -hex 32)" \
///     -U
/// ```
///
/// Secret-manager tooling (Vault, 1Password, AWS SSM) calls
/// `security add-generic-password` from its inject hook; the
/// Keychain is the handoff surface the app reads from.
public enum WebhookSecretResolver {

    /// Resolves the webhook HMAC secret from the macOS Keychain
    /// at service `com.spooktacular.webhook` and the supplied
    /// account. The item must already exist — this type never
    /// writes.
    ///
    /// - Parameter keychainAccount: account name under service
    ///   `com.spooktacular.webhook` (e.g., `github-webhook-org-acme`).
    /// - Returns: the trimmed, non-empty HMAC secret.
    /// - Throws: ``WebhookSecretError`` on every failure mode.
    public static func resolve(keychainAccount: String) throws -> String {
        guard let secret = WebhookKeychain.load(account: keychainAccount) else {
            throw WebhookSecretError.keychainMiss(account: keychainAccount)
        }
        return secret
    }
}

// MARK: - Webhook Keychain

/// Reads webhook HMAC secrets from the macOS Keychain under a
/// dedicated service name. Writes are intentionally not provided
/// here — the operator populates the Keychain via the `security`
/// CLI (or a secret-manager inject hook that wraps it), keeping
/// plaintext HMAC key material out of Swift's memory except
/// during the brief `SecItemCopyMatching` window.
public enum WebhookKeychain {

    /// Keychain service name. Follows the `com.spooktacular.*`
    /// convention used by the GitHub PAT resolver
    /// (`com.spooktacular.github`), the audit signing key
    /// (`com.spooktacular.merkle-audit`), and the break-glass
    /// operator key (`com.spooktacular.break-glass`).
    public static let service = "com.spooktacular.webhook"

    /// Returns the secret stored under `account`, or `nil` if the
    /// Keychain has no matching item.
    public static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Errors

/// Diagnostics for ``WebhookSecretResolver``. Every case carries
/// an actionable `recoverySuggestion` the CLI renders verbatim
/// so the operator can copy-paste a one-shot fix.
public enum WebhookSecretError: Error, LocalizedError, Sendable {
    case keychainMiss(account: String)

    public var errorDescription: String? {
        switch self {
        case .keychainMiss(let account):
            "Keychain has no item at service=com.spooktacular.webhook, account=\(account)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .keychainMiss(let account):
            "Add the secret with: " +
            "`security add-generic-password -s com.spooktacular.webhook " +
            "-a \(account) -w \"$(openssl rand -hex 32)\" -U`. " +
            "Confirm it's stored: " +
            "`security find-generic-password -s com.spooktacular.webhook " +
            "-a \(account)`."
        }
    }
}

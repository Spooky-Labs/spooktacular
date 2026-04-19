import Foundation
import Security

/// Resolves a GitHub runner registration token from the **macOS
/// Keychain only**.
///
/// ## Design: single protected path
///
/// Earlier revisions of this resolver accepted the token via an
/// environment variable (`SPOOK_GITHUB_TOKEN`), a CLI flag
/// (`--github-token`), and a file path (`--github-token-file`).
/// Each of those is reachable by malware running as the
/// logged-in user:
///
/// - **Env var**: visible in `ps auxwwe`, `launchctl print`,
///   and every child process' environment.
/// - **CLI flag**: visible in `ps auxww` and shell history.
/// - **File on disk**: readable by any process with the
///   logged-in user's UID (no hardware gate), and copied into
///   backup archives + crash reports.
///
/// Pre-1.0 we ship the clean design as the only design:
/// Keychain-only. The token stays behind `SecItemCopyMatching`,
/// which requires an unlocked Keychain bound to this device
/// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Sibling
/// processes reading `ps` or `/etc/**` see nothing.
///
/// ## Populating the Keychain
///
/// One-time setup per host, per token:
///
/// ```bash
/// security add-generic-password \
///     -s com.spooktacular.github \
///     -a <account-name> \
///     -w "$(read-token-from-wherever)" \
///     -U
/// ```
///
/// Vault / 1Password / AWS Secrets Manager integrations call
/// `security add-generic-password` from their inject hook —
/// the secret manager stays authoritative, the Keychain is just
/// the handoff surface the app reads from.
///
/// ## API
///
/// ``resolve(keychainAccount:)`` takes the account name and
/// returns the token on success, throwing ``GitHubTokenError``
/// otherwise. No flag-value, file-path, or environment
/// parameters — those paths were removed to honor the
/// single-path principle.
public enum GitHubTokenResolver {

    /// Resolves the GitHub runner registration token from the
    /// macOS Keychain at service `com.spooktacular.github` and
    /// the supplied account. The item must already exist — this
    /// type never writes. Secret-manager tooling (Vault,
    /// 1Password, SSM) is expected to populate the Keychain
    /// out-of-band via `security add-generic-password`.
    ///
    /// - Parameter keychainAccount: account name under service
    ///   `com.spooktacular.github`. Usually a scope-identifier
    ///   like `org-acme`, `personal-sandbox`, or
    ///   `ci-runner-pool-a`.
    /// - Returns: the trimmed, non-empty token.
    /// - Throws: ``GitHubTokenError`` on every failure mode.
    public static func resolve(keychainAccount: String) throws -> String {
        guard let token = GitHubKeychain.load(account: keychainAccount) else {
            throw GitHubTokenError.keychainMiss(account: keychainAccount)
        }
        return token
    }
}

// MARK: - GitHub Keychain

/// Reads GitHub registration tokens from the macOS Keychain under
/// a dedicated service name. Writes are intentionally not
/// provided here — the operator populates the Keychain via the
/// `security` CLI (or a Vault / 1Password inject hook that wraps
/// it), keeping plaintext PAT material out of Swift's memory
/// except during the brief `SecItemCopyMatching` window.
public enum GitHubKeychain {

    /// Keychain service name. Matches the pattern used by the
    /// guest agent (`com.spooktacular.agent`) and server
    /// (`com.spooktacular.api`).
    public static let service = "com.spooktacular.github"

    /// Returns the token stored under `account`, or `nil` if the
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
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Errors

/// Diagnostics for ``GitHubTokenResolver``. Every case carries
/// an actionable recovery hint the CLI renders verbatim so the
/// operator can copy-paste a one-shot fix.
public enum GitHubTokenError: Error, LocalizedError, Sendable {
    case keychainMiss(account: String)

    public var errorDescription: String? {
        switch self {
        case .keychainMiss(let account):
            "Keychain has no item at service=com.spooktacular.github, account=\(account)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .keychainMiss(let account):
            "Add the token with: " +
            "`security add-generic-password -s com.spooktacular.github " +
            "-a \(account) -w <token> -U`. " +
            "Confirm it's stored: " +
            "`security find-generic-password -s com.spooktacular.github " +
            "-a \(account)`."
        }
    }
}

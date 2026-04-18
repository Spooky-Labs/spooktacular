import Foundation
import Security

/// Resolves a GitHub runner registration token from one of four
/// sources, in priority order:
///
/// 1. `--github-token-file <path>` — token read from file,
///    trimmed of whitespace. Does not land in `ps` output.
///    Useful with Vault agent, 1Password secrets-inject, or any
///    other file-based secret injector.
/// 2. `--github-token-keychain <account>` — read from the macOS
///    Keychain under service `com.spooktacular.github`. The
///    token never touches plaintext disk and never appears in
///    `ps` or `launchctl print`. Most-protected path on
///    single-host deployments.
/// 3. `SPOOK_GITHUB_TOKEN` environment variable — visible to
///    the launching shell only, not propagated to subprocesses
///    by default.
/// 4. `--github-token <value>` — CLI flag, visible in `ps`,
///    shell history, and `launchctl print`. The caller gets a
///    warning when this path is taken.
///
/// Throws ``GitHubTokenError/missing`` when none of the sources
/// produced a value.
///
/// Lives in SpooktacularKit so tests can exercise the resolution
/// chain without building the `spook` executable — the typed
/// errors + the Keychain helper are the units worth testing, and
/// they should work standalone.
public enum GitHubTokenResolver {

    public static func resolve(
        flagValue: String?,
        filePath: String?,
        keychainAccount: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if let filePath {
            let raw: String
            do {
                raw = try String(contentsOf: URL(filePath: filePath), encoding: .utf8)
            } catch {
                throw GitHubTokenError.unreadableFile(path: filePath, underlying: error)
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw GitHubTokenError.emptyFile(path: filePath)
            }
            return trimmed
        }
        if let account = keychainAccount {
            guard let token = GitHubKeychain.load(account: account) else {
                throw GitHubTokenError.keychainMiss(account: account)
            }
            return token
        }
        if let env = environment["SPOOK_GITHUB_TOKEN"], !env.isEmpty {
            return env
        }
        if let flagValue, !flagValue.isEmpty {
            return flagValue
        }
        throw GitHubTokenError.missing
    }
}

// MARK: - GitHub Keychain

/// Reads GitHub registration tokens from the macOS Keychain under
/// a dedicated service name.
///
/// ## Threat model
///
/// The goal is to keep long-lived `ghp_*` PATs out of:
///
/// - The process table (`ps auxww` would leak `--github-token`).
/// - Shell history (`HISTFILE`).
/// - `launchctl print`, which shows a LaunchDaemon's environment.
/// - Post-mortem core dumps + crash reports.
/// - Backup archives that include `/etc/**` or `/var/**`.
///
/// The Keychain solves every one of those, at the cost of
/// requiring the operator to run one `security` command at setup
/// time. That's the right trade for enterprise deployments.
///
/// ## Storage
///
/// Tokens live under service `com.spooktacular.github` with the
/// operator-supplied account name as the discriminator. One host
/// can hold many tokens for different scopes (`org-acme`,
/// `personal-sandbox`, `ci-runner-pool-a`, etc.).
///
/// ## Insertion pattern
///
/// ```bash
/// security add-generic-password \
///     -s com.spooktacular.github \
///     -a org-acme \
///     -w "$(cat ~/secrets/runner-token)" \
///     -U  # update existing item if present
/// ```
///
/// No corresponding `store()` in this type — writes are the
/// operator's responsibility and typically come from an external
/// secret manager (Vault, 1Password CLI, SSM) via the `security`
/// CLI. Keeping reads here and writes out there matches the
/// principle of least privilege: `spook` never holds the
/// plaintext PAT long enough to accidentally log or write it.
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

/// Diagnostics for ``GitHubTokenResolver`` — every case carries an
/// actionable recovery hint so the CLI can render a one-shot
/// message the operator can copy-paste.
public enum GitHubTokenError: Error, LocalizedError, Sendable {
    case missing
    case emptyFile(path: String)
    case unreadableFile(path: String, underlying: any Error & Sendable)
    case keychainMiss(account: String)

    public var errorDescription: String? {
        switch self {
        case .missing:
            "No GitHub runner registration token supplied."
        case .emptyFile(let path):
            "GitHub token file at '\(path)' is empty."
        case .unreadableFile(let path, let err):
            "Cannot read GitHub token file at '\(path)': \(err.localizedDescription)"
        case .keychainMiss(let account):
            "Keychain has no item at service=com.spooktacular.github, account=\(account)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missing:
            "Store the token in the Keychain and use --github-token-keychain <account>. File- and env-var-based fallbacks are --github-token-file or SPOOK_GITHUB_TOKEN. The --github-token flag is dev-only."
        case .emptyFile:
            "Write the token to the file with trailing newline stripped, then chmod 600."
        case .unreadableFile:
            "Check the file exists and the daemon user can read it: `ls -l <path>`."
        case .keychainMiss(let account):
            "Add the token with: `security add-generic-password -s com.spooktacular.github -a \(account) -w <token> -U`. Confirm it's stored: `security find-generic-password -s com.spooktacular.github -a \(account)`."
        }
    }
}

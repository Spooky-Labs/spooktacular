import Foundation

/// Validated parameters for provisioning a VM as a zero-touch
/// GitHub Actions runner.
///
/// Carried from ``CreateVMSheet`` (GUI) through
/// `AppState.MacOSCreationRequest` to the create pipeline, mirroring
/// the CLI's `--github-runner` flag group (`--github-repo`,
/// `--github-token-keychain`, `--ephemeral`) as a single validated
/// value instead of four loose strings/bools.
///
/// The registration token itself is intentionally **not** part of
/// this type — see ``GitHubRunnerService/issueRegistrationToken(scope:)``.
/// GitHub registration tokens expire after one hour, so minting one
/// at sheet-submit time (potentially tens of minutes before the VM
/// finishes installing macOS) would routinely hand the guest an
/// already-expired token. ``keychainAccount`` is carried forward
/// instead, and the token is minted late — seconds before the VM
/// boots — by whichever pipeline consumes this request.
public struct RunnerRequest: Sendable, Equatable {

    /// GitHub repository in `owner/repo` format.
    public let repo: String

    /// Keychain account under service `com.spooktacular.github`
    /// holding the long-lived personal access token (PAT) used to
    /// mint registration tokens.
    public let keychainAccount: String

    /// Additional runner labels beyond the built-in `self-hosted`,
    /// `macOS`, and `ARM64` labels every runner gets.
    public let labels: [String]

    /// Whether the runner exits after completing one job.
    public let ephemeral: Bool

    /// Validates and constructs a runner request.
    ///
    /// Validates the `owner/repo` shape now — at sheet-submit time
    /// — rather than after the VM finishes a 10-20 minute macOS
    /// install. Reuses ``GitHubRunnerScope``'s parser (via the
    /// `repos/{owner}/{repo}` prefix every self-hosted-runner REST
    /// endpoint requires) so the two validation paths never drift.
    ///
    /// - Parameters:
    ///   - repo: GitHub repository in `owner/repo` format. Leading/
    ///     trailing whitespace is trimmed.
    ///   - keychainAccount: Keychain account name under service
    ///     `com.spooktacular.github`. Leading/trailing whitespace
    ///     is trimmed.
    ///   - labels: Additional runner labels. Defaults to none.
    ///   - ephemeral: Whether the runner exits after one job.
    ///     Defaults to `false`.
    /// - Throws: ``RunnerRequestError/emptyRepo`` or
    ///   ``RunnerRequestError/emptyKeychainAccount`` if either
    ///   required field is blank after trimming; any error
    ///   ``GitHubRunnerScope`` throws if `repo` is not a valid
    ///   `owner/repo` slug.
    public init(
        repo: String,
        keychainAccount: String,
        labels: [String] = [],
        ephemeral: Bool = false
    ) throws {
        let trimmedRepo = repo.trimmingCharacters(in: .whitespaces)
        let trimmedAccount = keychainAccount.trimmingCharacters(in: .whitespaces)
        guard !trimmedRepo.isEmpty else {
            throw RunnerRequestError.emptyRepo
        }
        guard !trimmedAccount.isEmpty else {
            throw RunnerRequestError.emptyKeychainAccount
        }
        // Shape-check now, using the same parser the mint-time
        // call site (`GitHubRunnerScope("repos/\(repo)")`) uses,
        // so a malformed "owner/repo" value fails fast at
        // sheet-submit time instead of after install.
        _ = try GitHubRunnerScope("repos/\(trimmedRepo)")

        self.repo = trimmedRepo
        self.keychainAccount = trimmedAccount
        self.labels = labels
        self.ephemeral = ephemeral
    }
}

/// Diagnostics for ``RunnerRequest``.
public enum RunnerRequestError: Error, LocalizedError, Sendable, Equatable {

    /// `repo` was empty (or all whitespace) after trimming.
    case emptyRepo

    /// `keychainAccount` was empty (or all whitespace) after
    /// trimming.
    case emptyKeychainAccount

    public var errorDescription: String? {
        switch self {
        case .emptyRepo:
            return "A GitHub repository is required for the runner template."
        case .emptyKeychainAccount:
            return "A Keychain account is required for the runner template."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .emptyRepo:
            return "Enter a repository in owner/repo form, e.g. acme-inc/platform."
        case .emptyKeychainAccount:
            return "Enter the Keychain account name storing the PAT. Add it first: "
                + "security add-generic-password -s com.spooktacular.github "
                + "-a <account> -w <PAT with repo admin scope> -U"
        }
    }
}

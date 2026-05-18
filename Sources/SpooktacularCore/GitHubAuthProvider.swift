import Foundation

/// Provides authentication tokens for the GitHub API.
///
/// Conform to this protocol to supply credentials for ``GitHubRunnerService``.
/// Implementations must be safe to use from any concurrency context.
///
/// ## Built-in Implementations
///
/// - ``GitHubPATAuth``: Authenticates with a static personal access token.
public protocol GitHubAuthProvider: Sendable {
    /// Returns an authentication token for the GitHub REST API.
    ///
    /// - Returns: A valid GitHub token string.
    /// - Throws: An error if the token cannot be obtained.
    func token() async throws -> String
}

/// Authenticates with a static personal access token.
///
/// Use this provider when you have a fine-grained or classic PAT.
///
/// ```swift
/// let auth = GitHubPATAuth(token: "ghp_…")
/// let service = GitHubRunnerService(auth: auth)
/// ```
public struct GitHubPATAuth: GitHubAuthProvider {
    private let pat: String

    /// Creates a PAT-based auth provider.
    ///
    /// - Parameter token: A GitHub personal access token.
    public init(token: String) { self.pat = token }

    /// Returns the stored personal access token.
    public func token() async throws -> String { pat }
}

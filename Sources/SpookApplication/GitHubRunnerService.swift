import Foundation
import SpookCore

// MARK: - Response Models

/// Decodes the `POST /actions/runners/registration-token` response.
struct RegistrationTokenResponse: Codable, Sendable {
    let token: String
}

// MARK: - Errors

/// Errors produced by ``GitHubRunnerService``.
public enum GitHubServiceError: Error, LocalizedError, Sendable {
    /// The server returned a response that is not a valid `HTTPURLResponse`.
    case invalidResponse
    /// The API returned a non-success HTTP status code.
    case apiError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid response."
        case .apiError(let statusCode, let body):
            return "GitHub API error \(statusCode): \(body)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned a non-HTTP response. Check that `api.github.com` resolves and is reachable; corporate proxies often strip API traffic."
        case .apiError(let statusCode, _):
            switch statusCode {
            case 401:
                return "Token authentication failed. The PAT may be revoked, expired, or missing `admin:repo_hook` / `repo` scope. Regenerate at github.com/settings/tokens."
            case 403:
                return "Rate-limited or missing scope. Check `X-RateLimit-Remaining` and confirm the PAT includes the `admin:org` (org-level) or `repo` (repo-level) scope required for registration tokens."
            case 404:
                return "Repo or org not found under the configured scope. Confirm the path format is `owner/repo` or `orgs/org` — not a URL."
            default:
                return "HTTP \(statusCode) from GitHub. Inspect the response body and https://status.github.com."
            }
        }
    }
}

// MARK: - Service

/// Manages GitHub Actions self-hosted runners via the REST API.
///
/// `GitHubRunnerService` is an actor that provides a safe, concurrent
/// interface to the GitHub Actions runner endpoints. It handles
/// authentication, request construction, and response decoding.
///
/// ## Usage
///
/// ```swift
/// let auth = GitHubPATAuth(token: "ghp_…")
/// let service = GitHubRunnerService(auth: auth)
///
/// let token = try await service.createRegistrationToken(scope: "repos/myorg/myrepo")
/// ```
public actor GitHubRunnerService {
    private let auth: any GitHubAuthProvider
    private let http: any HTTPClient
    private let log: any LogProvider

    private static let apiBase = "https://api.github.com"
    private static let apiVersion = "2022-11-28"

    /// Creates a new GitHub runner service.
    ///
    /// - Parameters:
    ///   - auth: The authentication provider to use for API requests.
    ///   - http: The HTTP client for making requests.
    ///   - log: The logger for diagnostic messages.
    public init(
        auth: any GitHubAuthProvider,
        http: any HTTPClient,
        log: any LogProvider = SilentLogProvider()
    ) {
        self.auth = auth
        self.http = http
        self.log = log
    }

    /// Creates a registration token for adding a self-hosted runner.
    ///
    /// - Parameter scope: The API scope, e.g. `"repos/OWNER/REPO"` or `"orgs/ORG"`.
    /// - Returns: The registration token string.
    /// - Throws: ``GitHubServiceError`` on failure.
    public func createRegistrationToken(scope: String) async throws -> String {
        let url = URL(string: "\(Self.apiBase)/\(scope)/actions/runners/registration-token")!
        let (data, _) = try await request(url: url, method: .post)
        let response = try JSONDecoder().decode(RegistrationTokenResponse.self, from: data)
        log.info("Created registration token for \(scope)")
        return response.token
    }

    /// Removes a self-hosted runner by its numeric ID.
    ///
    /// - Parameters:
    ///   - runnerId: The runner's numeric ID from GitHub.
    ///   - scope: The API scope, e.g. `"repos/OWNER/REPO"` or `"orgs/ORG"`.
    /// - Throws: ``GitHubServiceError`` on failure.
    public func removeRunner(runnerId: Int, scope: String) async throws {
        let url = URL(string: "\(Self.apiBase)/\(scope)/actions/runners/\(runnerId)")!
        let (_, _) = try await request(url: url, method: .delete)
        log.info("Removed runner \(runnerId) from \(scope)")
    }

    // MARK: - Private

    /// Builds and executes an authenticated GitHub API request.
    ///
    /// - Parameters:
    ///   - url: The fully qualified API URL.
    ///   - method: The HTTP method.
    /// - Returns: A tuple of the response body data and the HTTP response.
    /// - Throws: ``GitHubServiceError`` on non-success status codes.
    private func request(url: URL, method: DomainHTTPRequest.Method) async throws -> (Data, DomainHTTPResponse) {
        let bearerToken = try await auth.token()
        let request = DomainHTTPRequest(
            method: method,
            url: url,
            headers: [
                "Authorization": "Bearer \(bearerToken)",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": Self.apiVersion,
            ]
        )
        let response = try await http.execute(request)

        guard response.isSuccess else {
            let body = String(data: response.body, encoding: .utf8) ?? "<unreadable>"
            throw GitHubServiceError.apiError(statusCode: response.statusCode, body: body)
        }

        return (response.body, response)
    }
}

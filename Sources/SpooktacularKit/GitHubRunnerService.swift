import Foundation
import os

// MARK: - Response Models

/// Decodes the `POST /actions/runners/registration-token` response.
struct RegistrationTokenResponse: Codable, Sendable {
    let token: String
}

/// Decodes the `GET /actions/runners` response.
struct RunnerListResponse: Codable, Sendable {
    let runners: [RunnerSummary]
}

// MARK: - Public Models

/// A summary of a GitHub Actions self-hosted runner.
///
/// This struct maps to the runner objects returned by the
/// [GitHub Actions REST API](https://docs.github.com/en/rest/actions/self-hosted-runners).
public struct RunnerSummary: Codable, Sendable {
    /// The unique runner ID assigned by GitHub.
    public let id: Int
    /// The human-readable runner name.
    public let name: String
    /// The runner status, typically `"online"` or `"offline"`.
    public let status: String
    /// Whether the runner is currently executing a job.
    public let busy: Bool
    /// The labels assigned to this runner.
    public let labels: [RunnerLabel]

    /// A label attached to a GitHub Actions runner.
    public struct RunnerLabel: Codable, Sendable {
        /// The label name (e.g., `"self-hosted"`, `"macOS"`).
        public let name: String
    }
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
/// let runners = try await service.listRunners(scope: "repos/myorg/myrepo")
/// ```
public actor GitHubRunnerService {
    private let auth: any GitHubAuthProvider
    private let session: URLSession
    private let logger = Logger(subsystem: "com.spooktacular", category: "github")

    private static let apiBase = "https://api.github.com"
    private static let apiVersion = "2022-11-28"

    /// Creates a new GitHub runner service.
    ///
    /// - Parameters:
    ///   - auth: The authentication provider to use for API requests.
    ///   - session: The URL session to use. Defaults to `.shared`.
    public init(auth: any GitHubAuthProvider, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    /// Creates a registration token for adding a self-hosted runner.
    ///
    /// - Parameter scope: The API scope, e.g. `"repos/OWNER/REPO"` or `"orgs/ORG"`.
    /// - Returns: The registration token string.
    /// - Throws: ``GitHubServiceError`` on failure.
    public func createRegistrationToken(scope: String) async throws -> String {
        let url = URL(string: "\(Self.apiBase)/\(scope)/actions/runners/registration-token")!
        let (data, _) = try await request(url: url, method: "POST")
        let response = try JSONDecoder().decode(RegistrationTokenResponse.self, from: data)
        logger.info("Created registration token for \(scope, privacy: .public)")
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
        let (_, _) = try await request(url: url, method: "DELETE")
        logger.info("Removed runner \(runnerId) from \(scope, privacy: .public)")
    }

    /// Lists all self-hosted runners for the given scope.
    ///
    /// - Parameter scope: The API scope, e.g. `"repos/OWNER/REPO"` or `"orgs/ORG"`.
    /// - Returns: An array of ``RunnerSummary`` objects.
    /// - Throws: ``GitHubServiceError`` on failure.
    public func listRunners(scope: String) async throws -> [RunnerSummary] {
        let url = URL(string: "\(Self.apiBase)/\(scope)/actions/runners")!
        let (data, _) = try await request(url: url, method: "GET")
        let response = try JSONDecoder().decode(RunnerListResponse.self, from: data)
        logger.info("Listed \(response.runners.count) runners for \(scope, privacy: .public)")
        return response.runners
    }

    // MARK: - Private

    /// Builds and executes an authenticated GitHub API request.
    ///
    /// - Parameters:
    ///   - url: The fully qualified API URL.
    ///   - method: The HTTP method (e.g., `"GET"`, `"POST"`, `"DELETE"`).
    /// - Returns: A tuple of the response body data and the HTTP response.
    /// - Throws: ``GitHubServiceError`` on non-success status codes or invalid responses.
    private func request(url: URL, method: String) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method

        let bearerToken = try await auth.token()
        urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw GitHubServiceError.apiError(statusCode: httpResponse.statusCode, body: body)
        }

        return (data, httpResponse)
    }
}

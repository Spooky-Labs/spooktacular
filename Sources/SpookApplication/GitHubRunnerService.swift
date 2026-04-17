import Foundation
import SpookCore

// MARK: - Response Models

/// Decodes the `POST /actions/runners/registration-token` response.
///
/// The same payload shape is emitted for repo, org, and enterprise
/// scopes; the `expires_at` field is informational for clients that
/// want to proactively refresh before GitHub's one-hour TTL.
public struct RegistrationTokenResponse: Codable, Sendable {
    public let token: String
    public let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }

    public init(token: String, expiresAt: Date? = nil) {
        self.token = token
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try c.decode(String.self, forKey: .token)
        // GitHub returns `expires_at` as an ISO 8601 timestamp.
        // Older API responses use the canonical form (`...Z`); newer
        // ones include fractional seconds and an explicit offset
        // (`...123-08:00`). Accept both without pinning a specific
        // formatter at decoder construction time.
        if let raw = try c.decodeIfPresent(String.self, forKey: .expiresAt) {
            self.expiresAt = Self.parseTimestamp(raw)
        } else {
            self.expiresAt = nil
        }
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// A single runner record as returned by `GET /actions/runners/{runner_id}`.
///
/// Only the fields we need for the drain state machine are decoded —
/// GitHub returns `labels`, `os`, etc. that we ignore.
public struct RunnerRecord: Codable, Sendable {
    public let id: Int
    public let name: String
    public let status: String
    public let busy: Bool

    public init(id: Int, name: String, status: String, busy: Bool) {
        self.id = id
        self.name = name
        self.status = status
        self.busy = busy
    }
}

// MARK: - Scope

/// A strongly typed, validated GitHub self-hosted-runner scope.
///
/// GitHub's self-hosted-runner REST endpoints route off a path
/// prefix. The only forms the API accepts are `repos/{owner}/{repo}`,
/// `orgs/{org}`, and `enterprises/{enterprise}` — everything else
/// is a 404 at best and a data leak (wrong token, wrong target) at
/// worst. Validating the shape before we ever hit the network moves
/// that failure from production-at-3am to compile-time-in-tests.
public struct GitHubRunnerScope: Sendable, Equatable, Hashable {

    /// The raw scope path (`"repos/owner/repo"`, `"orgs/org"`, ...).
    public let rawValue: String

    /// The kind of scope, useful for picking the narrowest token.
    public enum Kind: Sendable, Equatable, Hashable {
        case repo(owner: String, name: String)
        case org(String)
        case enterprise(String)
    }

    /// The parsed form.
    public let kind: Kind

    /// Parses and validates a scope string.
    ///
    /// - Throws: ``GitHubServiceError/invalidScope(_:)`` if `raw` does not
    ///   match `^(repos/[^/]+/[^/]+|orgs/[^/]+|enterprises/[^/]+)$`.
    public init(_ raw: String) throws {
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        switch components.first {
        case "repos":
            guard components.count == 3,
                  !components[1].isEmpty, !components[1].contains("/"),
                  !components[2].isEmpty, !components[2].contains("/")
            else { throw GitHubServiceError.invalidScope(raw) }
            self.kind = .repo(owner: components[1], name: components[2])
        case "orgs":
            guard components.count == 2, !components[1].isEmpty
            else { throw GitHubServiceError.invalidScope(raw) }
            self.kind = .org(components[1])
        case "enterprises":
            guard components.count == 2, !components[1].isEmpty
            else { throw GitHubServiceError.invalidScope(raw) }
            self.kind = .enterprise(components[1])
        default:
            throw GitHubServiceError.invalidScope(raw)
        }
        self.rawValue = raw
    }

    /// The API path prefix, e.g. `"repos/acme/widgets"`.
    public var apiPath: String { rawValue }
}

// MARK: - Errors

/// Errors produced by ``GitHubRunnerService``.
public enum GitHubServiceError: Error, LocalizedError, Sendable, Equatable {
    /// The server returned a response that is not a valid `HTTPURLResponse`.
    case invalidResponse
    /// The API returned a non-success HTTP status code.
    case apiError(statusCode: Int, body: String)
    /// The caller passed a scope string that does not match the required shape.
    case invalidScope(String)
    /// A drain operation ran past its deadline with the runner still busy.
    case drainDeadlineExceeded(runnerId: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid response."
        case .apiError(let statusCode, let body):
            return "GitHub API error \(statusCode): \(body)"
        case .invalidScope(let raw):
            return "Invalid GitHub runner scope: '\(raw)'. Expected 'repos/{owner}/{repo}', 'orgs/{org}', or 'enterprises/{ent}'."
        case .drainDeadlineExceeded(let id):
            return "Runner \(id) did not become idle before the drain deadline."
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
        case .invalidScope:
            return "Pass a repo scope such as 'repos/acme/widgets' (narrowest), an org scope 'orgs/acme', or an enterprise scope 'enterprises/acme'."
        case .drainDeadlineExceeded:
            return "The runner is still executing a job. Either extend the drain deadline or cancel the in-flight workflow run in GitHub before removing the runner."
        }
    }
}

// MARK: - Issued Token Ledger

/// Short-term ledger of issued registration tokens, keyed by scope.
///
/// GitHub's self-hosted-runner API does not expose a revoke endpoint
/// for registration tokens — tokens are one-hour-TTL capability
/// strings (see [docs]). The next-best mitigation is to (a) mint the
/// most narrowly-scoped token the caller needs, (b) keep the
/// plaintext token in memory for only as long as the caller is
/// actively configuring a runner, and (c) drop it the moment the
/// runner reports `registered`. `IssuedTokenLedger` is the in-memory
/// bookkeeping actor that backs that lifecycle.
///
/// [docs]: https://docs.github.com/en/rest/actions/self-hosted-runners
public actor IssuedTokenLedger {

    /// A record of one issued registration token.
    public struct Record: Sendable, Equatable {
        public let scope: String
        public let token: String
        public let issuedAt: Date
        public init(scope: String, token: String, issuedAt: Date) {
            self.scope = scope
            self.token = token
            self.issuedAt = issuedAt
        }
    }

    private var records: [UUID: Record] = [:]

    public init() {}

    /// Records a new issued token and returns its opaque handle.
    public func track(scope: String, token: String, at date: Date = Date()) -> UUID {
        let id = UUID()
        records[id] = Record(scope: scope, token: token, issuedAt: date)
        return id
    }

    /// Looks up a tracked token by handle.
    public func token(for id: UUID) -> String? {
        records[id]?.token
    }

    /// Drops a tracked token (after the runner has successfully registered).
    ///
    /// The caller must invoke this as soon as the runner transitions
    /// to `registered`, which minimizes the in-memory exposure
    /// window. The token is also dropped automatically when
    /// ``sweepExpired(now:ttl:)`` ages it out past GitHub's one-hour
    /// TTL.
    public func drop(_ id: UUID) {
        records[id] = nil
    }

    /// How many tokens are currently tracked (for metrics / tests).
    public var trackedCount: Int { records.count }

    /// Evicts records older than `ttl` relative to `now`.
    ///
    /// GitHub registration tokens expire an hour after issue. Holding
    /// an expired token in process memory is useless and an unneeded
    /// secret-in-memory exposure.
    @discardableResult
    public func sweepExpired(
        now: Date = Date(),
        ttl: TimeInterval = 3600
    ) -> Int {
        let stale = records.filter { now.timeIntervalSince($0.value.issuedAt) >= ttl }
        for key in stale.keys { records[key] = nil }
        return stale.count
    }
}

// MARK: - Service

/// Manages GitHub Actions self-hosted runners via the REST API.
///
/// `GitHubRunnerService` is an actor that provides a safe, concurrent
/// interface to the GitHub Actions runner endpoints. It handles
/// authentication, request construction, and response decoding, plus
/// the in-memory hygiene around the one-hour-TTL registration tokens
/// GitHub issues.
///
/// ## Usage
///
/// ```swift
/// let scope = try GitHubRunnerScope("repos/myorg/myrepo")
/// let service = GitHubRunnerService(auth: GitHubPATAuth(token: "ghp_…"), http: URLSessionHTTPClient())
/// let issue = try await service.issueRegistrationToken(scope: scope)
/// // … configure runner with issue.token …
/// await service.revokeRegistrationToken(handle: issue.handle)
/// ```
public actor GitHubRunnerService {
    private let auth: any GitHubAuthProvider
    private let http: any HTTPClient
    private let log: any LogProvider
    private let ledger: IssuedTokenLedger

    private static let apiBase = "https://api.github.com"
    private static let apiVersion = "2022-11-28"

    /// A freshly issued registration token plus its in-memory handle.
    ///
    /// The handle is the identifier the caller passes back to
    /// ``revokeRegistrationToken(handle:)`` once the runner has
    /// registered; it lets the service drop the plaintext token
    /// without exposing it to the caller.
    public struct IssuedRegistrationToken: Sendable {
        public let handle: UUID
        public let token: String
        public let scope: GitHubRunnerScope
        public let expiresAt: Date?
    }

    /// Creates a new GitHub runner service.
    ///
    /// - Parameters:
    ///   - auth: The authentication provider to use for API requests.
    ///   - http: The HTTP client for making requests.
    ///   - log: The logger for diagnostic messages.
    ///   - ledger: The in-memory ledger for tracking issued tokens.
    ///     Defaults to a fresh per-service ledger; callers that want
    ///     to share a ledger across services may inject their own.
    public init(
        auth: any GitHubAuthProvider,
        http: any HTTPClient,
        log: any LogProvider = SilentLogProvider(),
        ledger: IssuedTokenLedger = IssuedTokenLedger()
    ) {
        self.auth = auth
        self.http = http
        self.log = log
        self.ledger = ledger
    }

    // MARK: - Registration tokens

    /// Issues a new runner registration token and records it in the ledger.
    ///
    /// Prefer the narrowest scope possible — a repo-scoped token
    /// (`repos/owner/repo`) can only register runners against that
    /// one repository, while an org-scoped token can register
    /// runners against every repository the org owns.
    ///
    /// - Parameter scope: The validated scope at which to mint the token.
    /// - Returns: The plaintext token plus its revocation handle.
    /// - Throws: ``GitHubServiceError`` on API failure.
    public func issueRegistrationToken(
        scope: GitHubRunnerScope
    ) async throws -> IssuedRegistrationToken {
        let url = try Self.apiURL("\(scope.apiPath)/actions/runners/registration-token")
        let (data, _) = try await request(url: url, method: .post)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RegistrationTokenResponse.self, from: data)
        let handle = await ledger.track(scope: scope.rawValue, token: decoded.token)
        log.info("Issued registration token for \(scope.rawValue)")
        return IssuedRegistrationToken(
            handle: handle,
            token: decoded.token,
            scope: scope,
            expiresAt: decoded.expiresAt
        )
    }

    /// Legacy wrapper that returns the token string and validates the scope.
    ///
    /// Exists because the CRD spec and older call sites pass a raw
    /// scope string. New call sites should prefer
    /// ``issueRegistrationToken(scope:)`` for the revocation handle.
    public func createRegistrationToken(scope: String) async throws -> String {
        let validated = try GitHubRunnerScope(scope)
        let issued = try await issueRegistrationToken(scope: validated)
        return issued.token
    }

    /// Drops an issued registration token from the in-memory ledger.
    ///
    /// Call this as soon as the runner reports a successful
    /// registration; see the type-level docs on
    /// ``IssuedTokenLedger`` for the rationale.
    public func revokeRegistrationToken(handle: UUID) async {
        await ledger.drop(handle)
        log.info("Dropped registration token handle \(handle.uuidString)")
    }

    /// The number of registration tokens currently held in memory.
    ///
    /// Exposed for tests and for the metrics pipeline.
    public func trackedTokenCount() async -> Int {
        await ledger.trackedCount
    }

    /// Ages out any registration tokens past GitHub's one-hour TTL.
    ///
    /// Safe to call on a timer (e.g., once per minute from the
    /// reconciler) — dropping an already-expired token is a no-op.
    @discardableResult
    public func sweepExpiredTokens(now: Date = Date()) async -> Int {
        await ledger.sweepExpired(now: now)
    }

    // MARK: - Runner fetch / remove

    /// Fetches a single runner's live state.
    ///
    /// Used by the drain state machine to poll `busy` status until the
    /// runner is idle.
    public func fetchRunner(id: Int, scope: GitHubRunnerScope) async throws -> RunnerRecord {
        let url = try Self.apiURL("\(scope.apiPath)/actions/runners/\(id)")
        let (data, _) = try await request(url: url, method: .get)
        return try JSONDecoder().decode(RunnerRecord.self, from: data)
    }

    /// Removes a self-hosted runner by its numeric ID.
    ///
    /// - Parameters:
    ///   - runnerId: The runner's numeric ID from GitHub.
    ///   - scope: The validated scope.
    /// - Throws: ``GitHubServiceError`` on failure.
    public func removeRunner(runnerId: Int, scope: GitHubRunnerScope) async throws {
        let url = try Self.apiURL("\(scope.apiPath)/actions/runners/\(runnerId)")
        _ = try await request(url: url, method: .delete)
        log.info("Removed runner \(runnerId) from \(scope.rawValue)")
    }

    /// Legacy string-scoped variant — validates the scope and
    /// delegates to ``removeRunner(runnerId:scope:)-(Int,GitHubRunnerScope)``.
    public func removeRunner(runnerId: Int, scope: String) async throws {
        let validated = try GitHubRunnerScope(scope)
        try await removeRunner(runnerId: runnerId, scope: validated)
    }

    // MARK: - Drain

    /// Waits for the runner to transition off `busy`, or throws if
    /// it's still busy at the deadline.
    ///
    /// Polls `GET /actions/runners/{id}` on `pollInterval` cadence. A
    /// 404 from GitHub is treated as "runner has already been
    /// removed" and returns success — any other error propagates.
    ///
    /// This is the core of the drain-before-delete sequence: mark
    /// the runner busy-unavailable (GitHub's label-based scheduler
    /// already stops matching new jobs to a runner that's executing
    /// one), wait until the in-flight job finishes, then call
    /// ``removeRunner(runnerId:scope:)``.
    ///
    /// - Parameters:
    ///   - runnerId: The GitHub runner ID.
    ///   - scope: The validated scope.
    ///   - deadline: The absolute date after which to give up.
    ///   - pollInterval: Delay between `busy` checks.
    ///   - clock: Source of `now`; tests inject a deterministic clock.
    ///   - sleep: Delay primitive; tests inject a no-op.
    public func waitForDrain(
        runnerId: Int,
        scope: GitHubRunnerScope,
        deadline: Date,
        pollInterval: TimeInterval = 5,
        clock: @Sendable () -> Date = { Date() },
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws {
        while clock() < deadline {
            let runner: RunnerRecord
            do {
                runner = try await fetchRunner(id: runnerId, scope: scope)
            } catch GitHubServiceError.apiError(statusCode: 404, _) {
                // Already gone — nothing to drain.
                return
            }
            if !runner.busy {
                return
            }
            try await sleep(pollInterval)
        }
        throw GitHubServiceError.drainDeadlineExceeded(runnerId: runnerId)
    }

    // MARK: - Private

    /// Builds a fully qualified GitHub API URL for the given path,
    /// throwing rather than force-unwrapping if something in the
    /// scope produces an invalid URL. The scope's shape has already
    /// been validated by ``GitHubRunnerScope`` at this point, so
    /// this throw is defense-in-depth — not a recoverable failure
    /// mode under normal operation.
    private static func apiURL(_ path: String) throws -> URL {
        guard let url = URL(string: "\(apiBase)/\(path)") else {
            throw GitHubServiceError.invalidScope(path)
        }
        return url
    }

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

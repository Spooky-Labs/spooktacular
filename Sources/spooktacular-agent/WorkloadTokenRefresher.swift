import Foundation

/// Fetches workload-identity tokens from the control plane on a
/// timer, writes them to the in-memory ``WorkloadTokenCache`` and
/// a disk file, and handles transient errors with exponential
/// backoff.
///
/// ## What it does
///
/// `spooktacular-agent` runs in every managed VM. The AWS / GCP /
/// Azure SDKs the guest workload uses pick up federated credentials
/// from a file path (e.g., `AWS_WEB_IDENTITY_TOKEN_FILE`) — so we
/// need two things there:
///
/// 1. A **live token**, refreshed before it expires, so the SDKs
///    always see a valid JWT.
/// 2. **On-disk persistence** at the path the SDKs are configured
///    to read, so zero SDK code changes are needed.
///
/// `WorkloadTokenRefresher` owns both. It loops:
///
/// ```
/// sleep until (expiry - refreshLead)
///   ↓
/// fetch new token from control-plane endpoint
///   ↓
/// on success → update cache + disk → reset backoff
/// on failure → exponential backoff (capped), retry
/// ```
///
/// ## Lifecycle
///
/// The refresher is `async`-started at agent boot via ``start()``
/// and stopped cooperatively via ``stop()``. A task cancel on the
/// owning `Task` is the preferred stop signal in practice; `stop()`
/// exists for symmetry with the rest of the agent daemons.
///
/// ## Thread safety
///
/// `actor`-isolated. Public methods are safe to call from any
/// concurrency context; the refresh timer runs inside the actor.
public actor WorkloadTokenRefresher {

    // MARK: - Configuration

    /// Immutable configuration for one refresher instance.
    public struct Configuration: Sendable {
        /// How early before `expiresAt` the refresher should try to
        /// mint a replacement. 120 s is the conservative default —
        /// enough headroom to cover a control-plane hiccup, short
        /// enough that we don't churn the key every few minutes.
        public let refreshLead: TimeInterval

        /// Maximum retry backoff. Beyond this we keep retrying at
        /// the cap rather than escalating forever.
        public let maxBackoff: TimeInterval

        /// First backoff delay after the first failure. Doubles on
        /// each subsequent failure until ``maxBackoff`` is reached.
        public let baseBackoff: TimeInterval

        /// On-disk path at which to persist the latest token for the
        /// workload SDKs to pick up. `nil` skips disk persistence
        /// (useful in tests).
        public let tokenFilePath: String?

        public init(
            refreshLead: TimeInterval = 120,
            baseBackoff: TimeInterval = 1,
            maxBackoff: TimeInterval = 60,
            tokenFilePath: String? = ProcessInfo.processInfo.environment["SPOOKTACULAR_WORKLOAD_TOKEN_FILE"]
        ) {
            self.refreshLead = refreshLead
            self.baseBackoff = baseBackoff
            self.maxBackoff = maxBackoff
            self.tokenFilePath = tokenFilePath
        }
    }

    // MARK: - Fetcher

    /// Control-plane fetch primitive: given an existing snapshot
    /// (or `nil`), returns the next one. Abstracted behind a
    /// closure so tests can inject canned sequences (success,
    /// transient failure, permanent failure) without standing up
    /// an HTTP server.
    public typealias Fetcher = @Sendable (_ previous: WorkloadTokenCache.Snapshot?) async throws -> WorkloadTokenCache.Snapshot

    // MARK: - State

    private let config: Configuration
    private let cache: WorkloadTokenCache
    private let fetcher: Fetcher
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var runTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a refresher with all dependencies injected.
    ///
    /// - Parameters:
    ///   - configuration: Timing + persistence config.
    ///   - cache: The in-memory cache to update.
    ///   - fetcher: Control-plane fetch primitive.
    ///   - clock: Source of `now`. Defaults to `Date()`; tests
    ///     inject a deterministic clock.
    ///   - sleep: Delay primitive. Defaults to `Task.sleep`;
    ///     tests inject a no-op.
    public init(
        configuration: Configuration = Configuration(),
        cache: WorkloadTokenCache = .shared,
        fetcher: @escaping Fetcher,
        clock: @Sendable @escaping () -> Date = { Date() },
        sleep: @Sendable @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.config = configuration
        self.cache = cache
        self.fetcher = fetcher
        self.clock = clock
        self.sleep = sleep
    }

    // MARK: - Control

    /// Starts the refresh loop as a detached task on this actor.
    ///
    /// Idempotent: calling twice with an already-running refresher
    /// is a no-op. The task runs until ``stop()`` is called or
    /// until it is externally cancelled.
    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cooperatively cancels the refresh loop and awaits its exit.
    public func stop() async {
        runTask?.cancel()
        await runTask?.value
        runTask = nil
    }

    // MARK: - Core loop

    /// Single iteration of the refresh loop, exposed for tests so
    /// we can step through the state machine deterministically
    /// without racing the real timer.
    ///
    /// Returns the delay the loop would sleep before the next
    /// iteration — tests assert on this to pin backoff semantics.
    @discardableResult
    public func tickOnce() async -> TimeInterval {
        do {
            let previous = cache.snapshot()
            let next = try await fetcher(previous)
            cache.replace(with: next)
            persistToDisk(next)
            return nextDelay(expiresAt: next.expiresAt)
        } catch {
            return nextBackoff()
        }
    }

    private func runLoop() async {
        var backoff: TimeInterval = config.baseBackoff
        while !Task.isCancelled {
            do {
                let previous = cache.snapshot()
                let next = try await fetcher(previous)
                cache.replace(with: next)
                persistToDisk(next)
                backoff = config.baseBackoff  // reset on success
                let delay = nextDelay(expiresAt: next.expiresAt)
                try await sleep(delay)
            } catch is CancellationError {
                return
            } catch {
                do {
                    try await sleep(backoff)
                } catch {
                    return
                }
                backoff = min(backoff * 2, config.maxBackoff)
            }
        }
    }

    // MARK: - Timing

    /// Computes the delay until the next refresh attempt: the
    /// token expiry minus `refreshLead`, clamped to `[0, ∞)`.
    func nextDelay(expiresAt: Date) -> TimeInterval {
        let target = expiresAt.addingTimeInterval(-config.refreshLead)
        return max(0, target.timeIntervalSince(clock()))
    }

    /// Computes the next backoff delay after a failure. Separate
    /// method so tests can exercise it directly.
    private var currentBackoff: TimeInterval = 0
    private func nextBackoff() -> TimeInterval {
        if currentBackoff == 0 {
            currentBackoff = config.baseBackoff
        } else {
            currentBackoff = min(currentBackoff * 2, config.maxBackoff)
        }
        return currentBackoff
    }

    // MARK: - Persistence

    /// Writes the raw JWT string to the configured disk path with
    /// mode `0600`. Errors are swallowed — a failed write must not
    /// crash the refresher; the in-memory cache stays valid and
    /// the next tick will retry.
    private func persistToDisk(_ snapshot: WorkloadTokenCache.Snapshot) {
        guard let path = config.tokenFilePath else { return }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let data = Data(snapshot.token.utf8)
            try data.write(to: url, options: [.atomic])
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        } catch {
            // Intentionally swallowed; logging is the agent-boot
            // layer's responsibility. A failed persistence write
            // does not invalidate the in-memory cache.
        }
    }
}

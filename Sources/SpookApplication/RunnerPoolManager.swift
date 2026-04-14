import SpookCore
/// The lifecycle mode for a runner pool.
///
/// Controls how runners are recycled after completing a job:
/// - ``ephemeral``: Runners are deleted after each job.
/// - ``warmPool``: Runners are recycled and reused.
/// - ``warmPoolFast``: Runners are recycled with optimized clone strategies.
public enum PoolMode: String, Codable, Sendable {
    case ephemeral
    case warmPool = "warm-pool"
    case warmPoolFast = "warm-pool-fast"
}

/// The desired state of a runner pool, derived from the CRD spec.
///
/// The reconciler compares this to the current ``RunnerStatus`` array and
/// produces the minimal set of ``PoolAction`` values needed to converge.
///
/// ## Example
///
/// ```swift
/// let desired = PoolDesiredState(
///     minRunners: 2,
///     maxRunners: 5,
///     sourceVM: "macos-14-base",
///     mode: .ephemeral,
///     preWarm: true
/// )
/// ```
public struct PoolDesiredState: Sendable {

    /// The minimum number of active runners the pool must maintain.
    public let minRunners: Int

    /// The maximum number of active runners the pool may have.
    public let maxRunners: Int

    /// The source VM image name used for cloning new runners.
    public let sourceVM: String

    /// The lifecycle mode controlling how runners are recycled.
    public let mode: PoolMode

    /// Whether to pre-warm an additional runner when all active runners are
    /// busy.
    public let preWarm: Bool

    /// Creates a new desired-state description.
    ///
    /// - Parameters:
    ///   - minRunners: Minimum active runners to maintain.
    ///   - maxRunners: Maximum active runners allowed.
    ///   - sourceVM: Source VM image name for cloning.
    ///   - mode: Lifecycle mode for the pool.
    ///   - preWarm: Whether to pre-warm an extra runner when all are busy.
    public init(
        minRunners: Int,
        maxRunners: Int,
        sourceVM: String,
        mode: PoolMode,
        preWarm: Bool
    ) {
        self.minRunners = minRunners
        self.maxRunners = maxRunners
        self.sourceVM = sourceVM
        self.mode = mode
        self.preWarm = preWarm
    }
}

/// The current status of a single runner in a pool.
///
/// Produced by inspecting the live runner state machines and fed into
/// ``RunnerPoolManager/reconcilePool(desired:current:)`` for reconciliation.
public struct RunnerStatus: Sendable {

    /// The unique name of this runner (e.g. `"runner-001"`).
    public let name: String

    /// The current state of this runner's lifecycle state machine.
    public let state: RunnerStateMachine.State

    /// How many times this runner has been retried after failure.
    public let retryCount: Int

    /// Creates a new runner status snapshot.
    ///
    /// - Parameters:
    ///   - name: Unique runner name.
    ///   - state: Current lifecycle state.
    ///   - retryCount: Number of retries so far.
    public init(name: String, state: RunnerStateMachine.State, retryCount: Int) {
        self.name = name
        self.state = state
        self.retryCount = retryCount
    }
}

/// An action the reconciler should take to converge pool state.
///
/// Returned by ``RunnerPoolManager/reconcilePool(desired:current:)`` as an
/// ordered list of operations the caller must execute.
public enum PoolAction: Sendable {

    /// Clone the source VM and create a new runner with the given name.
    case createRunner(name: String, sourceVM: String)

    /// Delete an existing runner by name.
    case deleteRunner(name: String)
}

/// Manages reconciliation of a runner pool's desired vs. actual state.
///
/// The pool manager is an actor that compares a ``PoolDesiredState`` to the
/// current ``RunnerStatus`` array and returns the minimal set of
/// ``PoolAction`` values needed to converge the two. It owns no I/O — the
/// caller is responsible for executing the returned actions.
///
/// ## Usage
///
/// ```swift
/// let manager = RunnerPoolManager()
/// let actions = await manager.reconcilePool(desired: desired, current: runners)
/// for action in actions { execute(action) }
/// ```
public actor RunnerPoolManager {

    /// Creates a new pool manager.
    public init() {}

    /// Compares desired to current state and returns the actions needed to
    /// converge.
    ///
    /// The algorithm:
    /// 1. Counts active runners (all except ``RunnerStateMachine/State/deleted``).
    /// 2. If active count is below ``PoolDesiredState/minRunners``, creates
    ///    enough runners to reach the minimum.
    /// 3. If ``PoolDesiredState/preWarm`` is `true` and every active runner is
    ///    busy, creates one additional pre-warmed runner.
    /// 4. Caps total actions so active count plus new runners never exceeds
    ///    ``PoolDesiredState/maxRunners``.
    ///
    /// Runner names follow the pattern `"runner-NNN"` where NNN is a
    /// zero-padded three-digit number based on the total existing runner count.
    ///
    /// - Parameters:
    ///   - desired: The target pool configuration from the CRD spec.
    ///   - current: A snapshot of all runners currently in the pool.
    /// - Returns: An ordered array of actions the reconciler must execute.
    public func reconcilePool(
        desired: PoolDesiredState,
        current: [RunnerStatus]
    ) -> [PoolAction] {
        let active = current.filter { $0.state != .deleted }
        let activeCount = active.count
        let busyCount = active.filter { $0.state == .busy }.count
        let existingCount = current.count

        var actions: [PoolAction] = []

        // Scale up to minRunners if below.
        if activeCount < desired.minRunners {
            let needed = desired.minRunners - activeCount
            for i in 0..<needed {
                let name = "runner-\(String(format: "%03d", existingCount + i + 1))"
                actions.append(.createRunner(name: name, sourceVM: desired.sourceVM))
            }
        }

        // Pre-warm: if all active runners are busy, add one more.
        if desired.preWarm, activeCount > 0, busyCount == activeCount,
           activeCount < desired.maxRunners
        {
            // Only add if we haven't already added runners above that would
            // satisfy this (e.g., if we scaled up, there are now non-busy
            // runners pending creation).
            if actions.isEmpty {
                let name = "runner-\(String(format: "%03d", existingCount + actions.count + 1))"
                actions.append(.createRunner(name: name, sourceVM: desired.sourceVM))
            }
        }

        // Cap so we never exceed maxRunners.
        let maxNewRunners = max(0, desired.maxRunners - activeCount)
        if actions.count > maxNewRunners {
            actions = Array(actions.prefix(maxNewRunners))
        }

        return actions
    }
}

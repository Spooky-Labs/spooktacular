/// A pure value-type state machine representing the lifecycle of a single
/// runner VM in a pool.
///
/// The reconciler drives this machine by calling ``transition(event:)`` and
/// executing the returned ``SideEffect`` array. The state machine itself has
/// **zero I/O, zero async, zero dependencies** — it is fully deterministic.
///
/// ## States
///
/// ```
/// requested → cloning → booting → registering → ready → busy → draining → recycling → [cloning | deleted]
/// Any state → failed (on timeout/error)
/// ```
///
/// ## Usage
///
/// ```swift
/// var machine = RunnerStateMachine(maxRetries: 3)
/// machine.sourceVM = "macos-14-base"
/// let effects = machine.transition(event: .nodeAvailable)
/// for effect in effects { execute(effect) }
/// ```
public struct RunnerStateMachine: Sendable, Codable {

    // MARK: - State

    /// Every possible state in the runner lifecycle.
    public enum State: String, Codable, Sendable, CaseIterable {
        case requested, cloning, booting, registering
        case ready, busy, draining, recycling
        case failed, deleted
    }

    // MARK: - Event

    /// External events that drive state transitions.
    public enum Event: Sendable {
        case nodeAvailable
        case cloneSucceeded, cloneFailed
        case healthCheckPassed, bootFailed
        case runnerRegistered, registrationFailed
        case jobStarted(jobId: String)
        case jobCompleted
        case runnerExited
        case vmStopped
        case drainComplete
        case recycleComplete, recycleFailed
        case timeout
        case retryRequested
    }

    // MARK: - Side Effect

    /// Commands the reconciler must execute after a transition.
    public enum SideEffect: Sendable, Equatable {
        case cloneVM(source: String)
        case startVM
        case stopVM
        case deleteVM
        case execProvisioningScript
        case deregisterRunner(runnerId: Int)
        case updateStatus(State)
        case scheduleTimeout(seconds: Int)
        case cancelTimeout
        case createReplacement

        /// An event was received that the state machine has no
        /// transition for from the current state.
        ///
        /// Previously these events were silently dropped — which is
        /// the exact antipattern flagged in the silent-failure sweep:
        /// a stuck runner produces no alert, no metric, no audit
        /// trail. Surface every protocol violation as a side effect
        /// the reconciler can log and emit a metric for.
        ///
        /// - Parameters:
        ///   - state: The state the machine was in when the event arrived.
        ///   - event: A human-readable description of the invalid event.
        case logProtocolViolation(state: State, event: String)

        /// Recycling completed with a non-empty ``sourceVM`` and the
        /// prior runner ID (if any) — the reconciler must record this
        /// so auditors can trace a runner's full clone-to-recycle
        /// lineage instead of seeing an orphan ``cloneVM`` effect.
        case auditRecycleComplete(priorRunnerId: Int?, sourceVM: String)

        /// Recycling transitioned into `.failed` because the state
        /// machine could not safely re-clone (e.g. ``sourceVM``
        /// empty). Recorded so the reconciler can page instead of
        /// silently dropping a VM back into a half-state.
        ///
        /// - Parameter reason: A machine-readable tag describing why
        ///   validation failed. Short enough for a Prometheus label.
        case recycleValidationFailed(reason: String)
    }

    // MARK: - Properties

    /// The current state of this runner.
    public private(set) var state: State

    /// How many times this runner has been retried after failure.
    public private(set) var retryCount: Int

    /// The maximum number of retries before the runner is permanently deleted.
    public let maxRetries: Int

    /// The source VM image name used for cloning.
    public var sourceVM: String = ""

    /// The GitHub runner ID, set after registration succeeds.
    public var runnerId: Int?

    /// The ID of the job currently being executed, if any.
    public var jobId: String?

    // MARK: - Initializer

    /// Creates a new runner state machine in the ``State/requested`` state.
    ///
    /// - Parameter maxRetries: Maximum retry attempts before the runner is
    ///   permanently deleted. Defaults to `3`.
    public init(maxRetries: Int = 3) {
        self.state = .requested
        self.retryCount = 0
        self.maxRetries = maxRetries
    }

    // MARK: - Transition

    /// Processes an event and returns the side effects the caller must execute.
    ///
    /// If the event is not valid for the current state, the state is
    /// unchanged and the method returns a single
    /// ``SideEffect/logProtocolViolation(state:event:)`` entry. The
    /// reconciler is expected to log this at `.warning` and increment
    /// a protocol-violation metric; previously invalid events were
    /// silently dropped, which masked real bugs in the controller.
    ///
    /// - Parameter event: The event to process.
    /// - Returns: An array of side effects to execute, in order.
    ///   Never empty for any non-``State/deleted`` state.
    public mutating func transition(event: Event) -> [SideEffect] {
        switch state {
        case .requested:
            return transitionFromRequested(event: event)
        case .cloning:
            return transitionFromCloning(event: event)
        case .booting:
            return transitionFromBooting(event: event)
        case .registering:
            return transitionFromRegistering(event: event)
        case .ready:
            return transitionFromReady(event: event)
        case .busy:
            return transitionFromBusy(event: event)
        case .draining:
            return transitionFromDraining(event: event)
        case .recycling:
            return transitionFromRecycling(event: event)
        case .failed:
            return transitionFromFailed(event: event)
        case .deleted:
            // Terminal state. No side effect — ``deleted`` must stay
            // an attractor to avoid zombie runners. Violations after
            // deletion are expected (controllers race; stale events
            // arrive) so we don't surface them as warnings.
            return []
        }
    }

    /// Builds a single-entry array recording the invalid event + the
    /// state it arrived in. Kept private and out-of-line so the
    /// per-state handlers stay focused on valid transitions.
    private func protocolViolation(for event: Event) -> [SideEffect] {
        [.logProtocolViolation(state: state, event: Self.describe(event))]
    }

    private static func describe(_ event: Event) -> String {
        switch event {
        case .nodeAvailable:         return "nodeAvailable"
        case .cloneSucceeded:        return "cloneSucceeded"
        case .cloneFailed:           return "cloneFailed"
        case .healthCheckPassed:     return "healthCheckPassed"
        case .bootFailed:            return "bootFailed"
        case .runnerRegistered:      return "runnerRegistered"
        case .registrationFailed:    return "registrationFailed"
        case .jobStarted(let id):    return "jobStarted(\(id))"
        case .jobCompleted:          return "jobCompleted"
        case .runnerExited:          return "runnerExited"
        case .vmStopped:             return "vmStopped"
        case .drainComplete:         return "drainComplete"
        case .recycleComplete:       return "recycleComplete"
        case .recycleFailed:         return "recycleFailed"
        case .timeout:               return "timeout"
        case .retryRequested:        return "retryRequested"
        }
    }

    // MARK: - Per-State Transition Handlers

    private mutating func transitionFromRequested(event: Event) -> [SideEffect] {
        switch event {
        case .nodeAvailable:
            state = .cloning
            return [.cloneVM(source: sourceVM), .scheduleTimeout(seconds: 120)]
        case .timeout:
            state = .failed
            return [.updateStatus(.failed)]
        default:
            return protocolViolation(for: event)
        }
    }

    private mutating func transitionFromCloning(event: Event) -> [SideEffect] {
        switch event {
        case .cloneSucceeded:
            state = .booting
            return [.cancelTimeout, .startVM, .scheduleTimeout(seconds: 180)]
        case .cloneFailed:
            state = .failed
            return [.cancelTimeout, .deleteVM, .updateStatus(.failed)]
        case .timeout:
            state = .failed
            return [.cancelTimeout, .deleteVM, .updateStatus(.failed)]
        default:
            return protocolViolation(for: event)
        }
    }

    private mutating func transitionFromBooting(event: Event) -> [SideEffect] {
        switch event {
        case .healthCheckPassed:
            state = .registering
            return [.cancelTimeout, .execProvisioningScript, .scheduleTimeout(seconds: 300)]
        case .bootFailed:
            state = .failed
            return [.cancelTimeout, .stopVM, .deleteVM, .updateStatus(.failed)]
        case .timeout:
            state = .failed
            return [.cancelTimeout, .stopVM, .deleteVM, .updateStatus(.failed)]
        default:
            return protocolViolation(for: event)
        }
    }

    private mutating func transitionFromRegistering(event: Event) -> [SideEffect] {
        switch event {
        case .runnerRegistered:
            state = .ready
            return [.cancelTimeout, .updateStatus(.ready)]
        case .registrationFailed:
            state = .failed
            return [.cancelTimeout, .stopVM, .deleteVM, .updateStatus(.failed)]
        case .timeout:
            state = .failed
            return [.cancelTimeout, .stopVM, .deleteVM, .updateStatus(.failed)]
        default:
            return protocolViolation(for: event)
        }
    }

    private mutating func transitionFromReady(event: Event) -> [SideEffect] {
        switch event {
        case .jobStarted(let id):
            state = .busy
            jobId = id
            return [.updateStatus(.busy)]
        case .runnerExited:
            state = .failed
            var effects: [SideEffect] = []
            if let id = runnerId {
                effects.append(.deregisterRunner(runnerId: id))
            }
            effects.append(.deleteVM)
            effects.append(.updateStatus(.failed))
            return effects
        default:
            return protocolViolation(for: event)
        }
    }

    private mutating func transitionFromBusy(event: Event) -> [SideEffect] {
        switch event {
        case .jobCompleted:
            state = .draining
            jobId = nil
            return [.scheduleTimeout(seconds: 60)]
        case .runnerExited:
            state = .draining
            jobId = nil
            return [.scheduleTimeout(seconds: 60)]
        case .vmStopped:
            state = .failed
            jobId = nil
            var effects: [SideEffect] = []
            if let id = runnerId {
                effects.append(.deregisterRunner(runnerId: id))
            }
            effects.append(.deleteVM)
            effects.append(.updateStatus(.failed))
            return effects
        default:
            return protocolViolation(for: event)
        }
    }

    private mutating func transitionFromDraining(event: Event) -> [SideEffect] {
        switch event {
        case .drainComplete:
            state = .recycling
            var effects: [SideEffect] = [.cancelTimeout]
            if let id = runnerId {
                effects.append(.deregisterRunner(runnerId: id))
            }
            runnerId = nil
            effects.append(.scheduleTimeout(seconds: 120))
            return effects
        case .timeout:
            state = .recycling
            var effects: [SideEffect] = []
            if let id = runnerId {
                effects.append(.deregisterRunner(runnerId: id))
            }
            effects.append(.stopVM)
            runnerId = nil
            effects.append(.scheduleTimeout(seconds: 120))
            return effects
        default:
            return protocolViolation(for: event)
        }
    }

    private mutating func transitionFromRecycling(event: Event) -> [SideEffect] {
        switch event {
        case .recycleComplete:
            // Guard the recycle→cloning transition: without a
            // ``sourceVM`` we'd emit `cloneVM(source: "")` and leave
            // the controller to fail mid-clone without an audit
            // record. Fail loudly into `.failed` instead.
            let priorRunner = runnerId
            guard !sourceVM.isEmpty else {
                state = .failed
                return [
                    .cancelTimeout,
                    .recycleValidationFailed(reason: "sourceVM-empty"),
                    .deleteVM,
                    .updateStatus(.failed),
                ]
            }
            state = .cloning
            return [
                .cancelTimeout,
                .auditRecycleComplete(priorRunnerId: priorRunner, sourceVM: sourceVM),
                .cloneVM(source: sourceVM),
                .scheduleTimeout(seconds: 120),
            ]
        case .recycleFailed:
            state = .failed
            return [.cancelTimeout, .deleteVM, .updateStatus(.failed)]
        case .timeout:
            state = .failed
            return [.cancelTimeout, .deleteVM, .updateStatus(.failed)]
        default:
            return protocolViolation(for: event)
        }
    }

    private mutating func transitionFromFailed(event: Event) -> [SideEffect] {
        switch event {
        case .retryRequested:
            if retryCount < maxRetries {
                retryCount += 1
                state = .cloning
                return [.cloneVM(source: sourceVM), .scheduleTimeout(seconds: 120)]
            } else {
                state = .deleted
                return [.createReplacement, .updateStatus(.deleted)]
            }
        default:
            return protocolViolation(for: event)
        }
    }

    // MARK: - Testing Support

    /// Sets the retry count directly. **Only for use in tests.**
    ///
    /// Production code should never call this — retry count is managed
    /// exclusively through ``transition(event:)``. Accessible via
    /// `@testable import`.
    internal mutating func setRetryCountForTesting(_ count: Int) {
        retryCount = count
    }
}

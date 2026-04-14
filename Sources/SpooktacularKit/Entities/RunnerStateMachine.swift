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
    public enum SideEffect: Sendable {
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
    /// If the event is not valid for the current state, the state is unchanged
    /// and an empty array is returned.
    ///
    /// - Parameter event: The event to process.
    /// - Returns: An array of side effects to execute, in order.
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
            return []
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
            return []
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
            return []
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
            return []
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
            return []
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
            return []
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
            return []
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
            return []
        }
    }

    private mutating func transitionFromRecycling(event: Event) -> [SideEffect] {
        switch event {
        case .recycleComplete:
            state = .cloning
            return [.cancelTimeout, .cloneVM(source: sourceVM), .scheduleTimeout(seconds: 120)]
        case .recycleFailed:
            state = .failed
            return [.cancelTimeout, .deleteVM, .updateStatus(.failed)]
        case .timeout:
            state = .failed
            return [.cancelTimeout, .deleteVM, .updateStatus(.failed)]
        default:
            return []
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
            return []
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

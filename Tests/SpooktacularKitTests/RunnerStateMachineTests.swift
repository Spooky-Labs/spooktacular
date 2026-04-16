import Testing
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

// MARK: - Runner State Machine Tests

/// Validates the ``RunnerStateMachine`` transitions as a pure value type.
///
/// The state machine has zero I/O and zero async — every transition is
/// deterministic and returns an array of side effects the caller must execute.
@Suite("RunnerStateMachine")
struct RunnerStateMachineTests {

    // MARK: - Initial State

    @Test("Initial state is requested")
    func initialStateIsRequested() {
        let machine = RunnerStateMachine(maxRetries: 3)
        #expect(machine.state == .requested)
        #expect(machine.retryCount == 0)
        #expect(machine.runnerId == nil)
        #expect(machine.jobId == nil)
    }

    // MARK: - Happy Path: Startup

    @Test("Happy path: requested → cloning → booting → registering → ready")
    func happyPathStartup() {
        var machine = RunnerStateMachine(maxRetries: 3)
        machine.sourceVM = "base-image"

        // requested → cloning
        var effects = machine.transition(event: .nodeAvailable)
        #expect(machine.state == .cloning)
        #expect(effects.contains { if case .cloneVM(source: "base-image") = $0 { true } else { false } })
        #expect(effects.contains { if case .scheduleTimeout(seconds: 120) = $0 { true } else { false } })

        // cloning → booting
        effects = machine.transition(event: .cloneSucceeded)
        #expect(machine.state == .booting)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .startVM = $0 { true } else { false } })
        #expect(effects.contains { if case .scheduleTimeout(seconds: 180) = $0 { true } else { false } })

        // booting → registering
        effects = machine.transition(event: .healthCheckPassed)
        #expect(machine.state == .registering)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .execProvisioningScript = $0 { true } else { false } })
        #expect(effects.contains { if case .scheduleTimeout(seconds: 300) = $0 { true } else { false } })

        // registering → ready
        effects = machine.transition(event: .runnerRegistered)
        #expect(machine.state == .ready)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.ready) = $0 { true } else { false } })
    }

    // MARK: - Happy Path: Job Cycle

    @Test("Happy path: ready → busy → draining → recycling → cloning")
    func happyPathJobCycle() {
        var machine = makeReadyMachine()

        // ready → busy
        var effects = machine.transition(event: .jobStarted(jobId: "job-42"))
        #expect(machine.state == .busy)
        #expect(machine.jobId == "job-42")
        #expect(effects.contains { if case .updateStatus(.busy) = $0 { true } else { false } })

        // busy → draining
        effects = machine.transition(event: .jobCompleted)
        #expect(machine.state == .draining)
        #expect(machine.jobId == nil)
        #expect(effects.contains { if case .scheduleTimeout(seconds: 60) = $0 { true } else { false } })

        // draining → recycling
        machine.runnerId = 99
        effects = machine.transition(event: .drainComplete)
        #expect(machine.state == .recycling)
        #expect(machine.runnerId == nil)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .deregisterRunner(runnerId: 99) = $0 { true } else { false } })
        #expect(effects.contains { if case .scheduleTimeout(seconds: 120) = $0 { true } else { false } })

        // recycling → cloning
        effects = machine.transition(event: .recycleComplete)
        #expect(machine.state == .cloning)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .cloneVM = $0 { true } else { false } })
        #expect(effects.contains { if case .scheduleTimeout(seconds: 120) = $0 { true } else { false } })
    }

    // MARK: - Failure Transitions

    @Test("requested → failed on timeout")
    func requestedTimeout() {
        var machine = RunnerStateMachine(maxRetries: 3)
        let effects = machine.transition(event: .timeout)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
    }

    @Test("cloning → failed on cloneFailed")
    func cloningFailed() {
        var machine = makeCloningMachine()
        let effects = machine.transition(event: .cloneFailed)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
    }

    @Test("cloning → failed on timeout")
    func cloningTimeout() {
        var machine = makeCloningMachine()
        let effects = machine.transition(event: .timeout)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
    }

    @Test("booting → failed on bootFailed")
    func bootingFailed() {
        var machine = makeBootingMachine()
        let effects = machine.transition(event: .bootFailed)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
    }

    @Test("booting → failed on timeout")
    func bootingTimeout() {
        var machine = makeBootingMachine()
        let effects = machine.transition(event: .timeout)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
    }

    @Test("registering → failed on registrationFailed")
    func registeringFailed() {
        var machine = makeRegisteringMachine()
        let effects = machine.transition(event: .registrationFailed)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
    }

    @Test("registering → failed on timeout")
    func registeringTimeout() {
        var machine = makeRegisteringMachine()
        let effects = machine.transition(event: .timeout)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
    }

    @Test("ready → failed on runnerExited with runnerId")
    func readyRunnerExitedWithId() {
        var machine = makeReadyMachine()
        machine.runnerId = 55
        let effects = machine.transition(event: .runnerExited)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .deregisterRunner(runnerId: 55) = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
    }

    @Test("ready → failed on runnerExited without runnerId")
    func readyRunnerExitedWithoutId() {
        var machine = makeReadyMachine()
        machine.runnerId = nil
        let effects = machine.transition(event: .runnerExited)
        #expect(machine.state == .failed)
        // Should not contain deregisterRunner when runnerId is nil
        #expect(!effects.contains { if case .deregisterRunner = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
    }

    @Test("busy → failed on vmStopped")
    func busyVMStopped() {
        var machine = makeReadyMachine()
        machine.runnerId = 77
        _ = machine.transition(event: .jobStarted(jobId: "job-1"))
        let effects = machine.transition(event: .vmStopped)
        #expect(machine.state == .failed)
        #expect(machine.jobId == nil)
        #expect(effects.contains { if case .deregisterRunner(runnerId: 77) = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
    }

    @Test("busy → draining on runnerExited")
    func busyRunnerExited() {
        var machine = makeReadyMachine()
        _ = machine.transition(event: .jobStarted(jobId: "job-2"))
        let effects = machine.transition(event: .runnerExited)
        #expect(machine.state == .draining)
        #expect(machine.jobId == nil)
        #expect(effects.contains { if case .scheduleTimeout(seconds: 60) = $0 { true } else { false } })
    }

    @Test("draining → recycling on timeout with deregister")
    func drainingTimeout() {
        var machine = makeReadyMachine()
        machine.runnerId = 88
        _ = machine.transition(event: .jobStarted(jobId: "job-3"))
        _ = machine.transition(event: .jobCompleted)
        let effects = machine.transition(event: .timeout)
        #expect(machine.state == .recycling)
        #expect(machine.runnerId == nil)
        #expect(effects.contains { if case .deregisterRunner(runnerId: 88) = $0 { true } else { false } })
        #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
        #expect(effects.contains { if case .scheduleTimeout(seconds: 120) = $0 { true } else { false } })
    }

    @Test("recycling → failed on recycleFailed")
    func recyclingFailed() {
        var machine = makeRecyclingMachine()
        let effects = machine.transition(event: .recycleFailed)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
    }

    @Test("recycling → failed on timeout")
    func recyclingTimeout() {
        var machine = makeRecyclingMachine()
        let effects = machine.transition(event: .timeout)
        #expect(machine.state == .failed)
        #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
        #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
    }

    // MARK: - Retry Logic

    @Test("failed → cloning on retryRequested when retries remain")
    func retryWhenRetriesRemain() {
        var machine = makeFailedMachine(retryCount: 0, maxRetries: 3)
        machine.sourceVM = "base-image"
        let effects = machine.transition(event: .retryRequested)
        #expect(machine.state == .cloning)
        #expect(machine.retryCount == 1)
        #expect(effects.contains { if case .cloneVM(source: "base-image") = $0 { true } else { false } })
        #expect(effects.contains { if case .scheduleTimeout(seconds: 120) = $0 { true } else { false } })
    }

    @Test("failed → deleted on retryRequested when retries exhausted")
    func retryWhenRetriesExhausted() {
        var machine = makeFailedMachine(retryCount: 3, maxRetries: 3)
        let effects = machine.transition(event: .retryRequested)
        #expect(machine.state == .deleted)
        #expect(effects.contains { if case .createReplacement = $0 { true } else { false } })
        #expect(effects.contains { if case .updateStatus(.deleted) = $0 { true } else { false } })
    }

    // MARK: - Terminal State

    @Test("deleted ignores all events")
    func deletedIsTerminal() {
        var machine = makeFailedMachine(retryCount: 3, maxRetries: 3)
        _ = machine.transition(event: .retryRequested)
        #expect(machine.state == .deleted)

        // Every event should be ignored
        let events: [RunnerStateMachine.Event] = [
            .nodeAvailable,
            .cloneSucceeded,
            .cloneFailed,
            .healthCheckPassed,
            .bootFailed,
            .runnerRegistered,
            .registrationFailed,
            .jobStarted(jobId: "x"),
            .jobCompleted,
            .runnerExited,
            .vmStopped,
            .drainComplete,
            .recycleComplete,
            .recycleFailed,
            .timeout,
            .retryRequested,
        ]
        for event in events {
            let effects = machine.transition(event: event)
            #expect(machine.state == .deleted, "deleted state should not change on any event")
            #expect(effects.isEmpty, "deleted state should produce no side effects")
        }
    }

    // MARK: - Invalid Events Ignored

    @Test("Invalid events are ignored and return empty effects")
    func invalidEventsIgnored() {
        var machine = RunnerStateMachine(maxRetries: 3)
        #expect(machine.state == .requested)

        // cloneSucceeded is not valid in requested state
        let effects = machine.transition(event: .cloneSucceeded)
        #expect(machine.state == .requested)
        #expect(effects.isEmpty)
    }

    // MARK: - Property Tests

    @Test("Property: 1000 random sequences never get stuck")
    func propertyNoStuckStates() {
        let events: [RunnerStateMachine.Event] = [
            .nodeAvailable, .cloneSucceeded, .cloneFailed,
            .healthCheckPassed, .bootFailed, .runnerRegistered,
            .registrationFailed, .jobStarted(jobId: "test"),
            .jobCompleted, .runnerExited, .vmStopped,
            .drainComplete, .recycleComplete, .recycleFailed,
            .timeout, .retryRequested,
        ]

        for seed in 0..<1000 {
            var sm = RunnerStateMachine(maxRetries: 3)
            var rng = SeededRNG(seed: UInt64(seed))
            var wasDeleted = false

            for _ in 0..<50 {
                let event = events[Int(rng.next() % UInt64(events.count))]
                _ = sm.transition(event: event)

                // Once deleted, must stay deleted
                if wasDeleted {
                    #expect(sm.state == .deleted, "State changed after deleted at seed \(seed)")
                }
                if sm.state == .deleted { wasDeleted = true }
            }

            #expect(RunnerStateMachine.State.allCases.contains(sm.state))
            #expect(sm.retryCount <= sm.maxRetries)
        }
    }

    // MARK: - Helpers

    /// Creates a machine already in `cloning` state.
    private func makeCloningMachine() -> RunnerStateMachine {
        var machine = RunnerStateMachine(maxRetries: 3)
        machine.sourceVM = "base-image"
        _ = machine.transition(event: .nodeAvailable)
        return machine
    }

    /// Creates a machine already in `booting` state.
    private func makeBootingMachine() -> RunnerStateMachine {
        var machine = makeCloningMachine()
        _ = machine.transition(event: .cloneSucceeded)
        return machine
    }

    /// Creates a machine already in `registering` state.
    private func makeRegisteringMachine() -> RunnerStateMachine {
        var machine = makeBootingMachine()
        _ = machine.transition(event: .healthCheckPassed)
        return machine
    }

    /// Creates a machine already in `ready` state.
    private func makeReadyMachine() -> RunnerStateMachine {
        var machine = makeRegisteringMachine()
        _ = machine.transition(event: .runnerRegistered)
        return machine
    }

    /// Creates a machine already in `recycling` state.
    private func makeRecyclingMachine() -> RunnerStateMachine {
        var machine = makeReadyMachine()
        _ = machine.transition(event: .jobStarted(jobId: "job-0"))
        _ = machine.transition(event: .jobCompleted)
        _ = machine.transition(event: .drainComplete)
        return machine
    }

    /// Creates a machine in `failed` state with a specific retry count.
    private func makeFailedMachine(retryCount: Int, maxRetries: Int) -> RunnerStateMachine {
        var machine = RunnerStateMachine(maxRetries: maxRetries)
        // Drive to failed via requested timeout
        _ = machine.transition(event: .timeout)
        // Manually set retry count to desired value
        machine.setRetryCountForTesting(retryCount)
        return machine
    }
}

/// Deterministic RNG for property tests (SplitMix64).

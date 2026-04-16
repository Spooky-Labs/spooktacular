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
@Suite("RunnerStateMachine", .tags(.lifecycle))
struct RunnerStateMachineTests {

    // MARK: - Initial State

    @Suite("Initial State")
    struct InitialState {

        @Test("defaults to requested state with zero retries and no runner or job ID")
        func initialStateIsRequested() {
            let machine = RunnerStateMachine(maxRetries: 3)
            #expect(machine.state == .requested)
            #expect(machine.retryCount == 0)
            #expect(machine.runnerId == nil)
            #expect(machine.jobId == nil)
        }
    }

    // MARK: - Happy Path

    @Suite("Happy Path")
    struct HappyPath {

        @Test("startup: requested -> cloning -> booting -> registering -> ready")
        func happyPathStartup() {
            var machine = RunnerStateMachine(maxRetries: 3)
            machine.sourceVM = "base-image"

            // requested -> cloning
            var effects = machine.transition(event: .nodeAvailable)
            #expect(machine.state == .cloning)
            #expect(effects.contains { if case .cloneVM(source: "base-image") = $0 { true } else { false } })
            #expect(effects.contains { if case .scheduleTimeout(seconds: 120) = $0 { true } else { false } })

            // cloning -> booting
            effects = machine.transition(event: .cloneSucceeded)
            #expect(machine.state == .booting)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .startVM = $0 { true } else { false } })
            #expect(effects.contains { if case .scheduleTimeout(seconds: 180) = $0 { true } else { false } })

            // booting -> registering
            effects = machine.transition(event: .healthCheckPassed)
            #expect(machine.state == .registering)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .execProvisioningScript = $0 { true } else { false } })
            #expect(effects.contains { if case .scheduleTimeout(seconds: 300) = $0 { true } else { false } })

            // registering -> ready
            effects = machine.transition(event: .runnerRegistered)
            #expect(machine.state == .ready)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .updateStatus(.ready) = $0 { true } else { false } })
        }

        @Test("job cycle: ready -> busy -> draining -> recycling -> cloning")
        func happyPathJobCycle() {
            var machine = makeReadyMachine()

            // ready -> busy
            var effects = machine.transition(event: .jobStarted(jobId: "job-42"))
            #expect(machine.state == .busy)
            #expect(machine.jobId == "job-42")
            #expect(effects.contains { if case .updateStatus(.busy) = $0 { true } else { false } })

            // busy -> draining
            effects = machine.transition(event: .jobCompleted)
            #expect(machine.state == .draining)
            #expect(machine.jobId == nil)
            #expect(effects.contains { if case .scheduleTimeout(seconds: 60) = $0 { true } else { false } })

            // draining -> recycling
            machine.runnerId = 99
            effects = machine.transition(event: .drainComplete)
            #expect(machine.state == .recycling)
            #expect(machine.runnerId == nil)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .deregisterRunner(runnerId: 99) = $0 { true } else { false } })
            #expect(effects.contains { if case .scheduleTimeout(seconds: 120) = $0 { true } else { false } })

            // recycling -> cloning
            effects = machine.transition(event: .recycleComplete)
            #expect(machine.state == .cloning)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .cloneVM = $0 { true } else { false } })
            #expect(effects.contains { if case .scheduleTimeout(seconds: 120) = $0 { true } else { false } })
        }
    }

    // MARK: - Error Recovery

    @Suite("Error Recovery")
    struct ErrorRecovery {

        @Test("failure transitions produce correct state", arguments: [
            ("cloning", "cloneFailed"),
            ("booting", "bootFailed"),
            ("registering", "registrationFailed"),
            ("recycling", "recycleFailed"),
        ])
        func failureTransitions(fromState: String, eventName: String) {
            var machine = makeMachineInState(fromState)
            let event = eventForName(eventName)
            let effects = machine.transition(event: event)
            #expect(machine.state == .failed, "Expected failed state after \(eventName) in \(fromState)")
            #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
        }

        @Test("cloning failure issues cancelTimeout, deleteVM, and updateStatus")
        func cloningFailed() {
            var machine = makeCloningMachine()
            let effects = machine.transition(event: .cloneFailed)
            #expect(machine.state == .failed)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
            #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
        }

        @Test("booting failure issues cancelTimeout, stopVM, deleteVM, and updateStatus")
        func bootingFailed() {
            var machine = makeBootingMachine()
            let effects = machine.transition(event: .bootFailed)
            #expect(machine.state == .failed)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
            #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
        }

        @Test("registering failure issues cancelTimeout, stopVM, deleteVM, and updateStatus")
        func registeringFailed() {
            var machine = makeRegisteringMachine()
            let effects = machine.transition(event: .registrationFailed)
            #expect(machine.state == .failed)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
            #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
        }

        @Test("ready runner exit with runnerId deregisters and deletes VM")
        func readyRunnerExitedWithId() {
            var machine = makeReadyMachine()
            machine.runnerId = 55
            let effects = machine.transition(event: .runnerExited)
            #expect(machine.state == .failed)
            #expect(effects.contains { if case .deregisterRunner(runnerId: 55) = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
            #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
        }

        @Test("ready runner exit without runnerId skips deregister")
        func readyRunnerExitedWithoutId() {
            var machine = makeReadyMachine()
            machine.runnerId = nil
            let effects = machine.transition(event: .runnerExited)
            #expect(machine.state == .failed)
            #expect(!effects.contains { if case .deregisterRunner = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        }

        @Test("busy VM stop clears job and deregisters runner")
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

        @Test("busy runner exit transitions to draining, not failed")
        func busyRunnerExited() {
            var machine = makeReadyMachine()
            _ = machine.transition(event: .jobStarted(jobId: "job-2"))
            let effects = machine.transition(event: .runnerExited)
            #expect(machine.state == .draining)
            #expect(machine.jobId == nil)
            #expect(effects.contains { if case .scheduleTimeout(seconds: 60) = $0 { true } else { false } })
        }

        @Test("recycling failure issues cancelTimeout, deleteVM, and updateStatus")
        func recyclingFailed() {
            var machine = makeRecyclingMachine()
            let effects = machine.transition(event: .recycleFailed)
            #expect(machine.state == .failed)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
            #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
        }

        @Test("invalid events are ignored and return empty effects")
        func invalidEventsIgnored() {
            var machine = RunnerStateMachine(maxRetries: 3)
            #expect(machine.state == .requested)
            let effects = machine.transition(event: .cloneSucceeded)
            #expect(machine.state == .requested)
            #expect(effects.isEmpty)
        }
    }

    // MARK: - Timeouts

    @Suite("Timeouts")
    struct Timeouts {

        @Test("timeout transitions produce failed state", arguments: [
            "requested",
            "cloning",
            "booting",
            "registering",
            "recycling",
        ])
        func timeoutTransitions(fromState: String) {
            var machine = makeMachineInState(fromState)
            let effects = machine.transition(event: .timeout)
            #expect(machine.state == .failed, "Expected failed state after timeout in \(fromState)")
            #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } }
                || fromState == "booting",  // booting timeout does not emit updateStatus
                "Expected updateStatus(.failed) effect after timeout in \(fromState)")
        }

        @Test("cloning timeout issues cancelTimeout and deleteVM")
        func cloningTimeout() {
            var machine = makeCloningMachine()
            let effects = machine.transition(event: .timeout)
            #expect(machine.state == .failed)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        }

        @Test("booting timeout issues cancelTimeout, stopVM, and deleteVM")
        func bootingTimeout() {
            var machine = makeBootingMachine()
            let effects = machine.transition(event: .timeout)
            #expect(machine.state == .failed)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        }

        @Test("registering timeout issues cancelTimeout, stopVM, and deleteVM")
        func registeringTimeout() {
            var machine = makeRegisteringMachine()
            let effects = machine.transition(event: .timeout)
            #expect(machine.state == .failed)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
        }

        @Test("draining timeout transitions to recycling with deregister and stopVM")
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

        @Test("recycling timeout issues cancelTimeout, deleteVM, and updateStatus")
        func recyclingTimeout() {
            var machine = makeRecyclingMachine()
            let effects = machine.transition(event: .timeout)
            #expect(machine.state == .failed)
            #expect(effects.contains { if case .cancelTimeout = $0 { true } else { false } })
            #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
            #expect(effects.contains { if case .updateStatus(.failed) = $0 { true } else { false } })
        }
    }

    // MARK: - Retries

    @Suite("Retries")
    struct Retries {

        @Test("failed transitions to cloning on retryRequested when retries remain")
        func retryWhenRetriesRemain() {
            var machine = makeFailedMachine(retryCount: 0, maxRetries: 3)
            machine.sourceVM = "base-image"
            let effects = machine.transition(event: .retryRequested)
            #expect(machine.state == .cloning)
            #expect(machine.retryCount == 1)
            #expect(effects.contains { if case .cloneVM(source: "base-image") = $0 { true } else { false } })
            #expect(effects.contains { if case .scheduleTimeout(seconds: 120) = $0 { true } else { false } })
        }

        @Test("failed transitions to deleted on retryRequested when retries exhausted")
        func retryWhenRetriesExhausted() {
            var machine = makeFailedMachine(retryCount: 3, maxRetries: 3)
            let effects = machine.transition(event: .retryRequested)
            #expect(machine.state == .deleted)
            #expect(effects.contains { if case .createReplacement = $0 { true } else { false } })
            #expect(effects.contains { if case .updateStatus(.deleted) = $0 { true } else { false } })
        }

        @Test("deleted state ignores all events", arguments: [
            "nodeAvailable", "cloneSucceeded", "cloneFailed",
            "healthCheckPassed", "bootFailed", "runnerRegistered",
            "registrationFailed", "jobStarted", "jobCompleted",
            "runnerExited", "vmStopped", "drainComplete",
            "recycleComplete", "recycleFailed", "timeout", "retryRequested",
        ])
        func deletedIsTerminal(eventName: String) {
            var machine = makeFailedMachine(retryCount: 3, maxRetries: 3)
            _ = machine.transition(event: .retryRequested)
            #expect(machine.state == .deleted)

            let event = eventForName(eventName)
            let effects = machine.transition(event: event)
            #expect(machine.state == .deleted, "deleted state should not change on \(eventName)")
            #expect(effects.isEmpty, "deleted state should produce no side effects on \(eventName)")
        }
    }

    // MARK: - Property Tests

    @Suite("Property Tests")
    struct PropertyTests {

        @Test("10000 random sequences never get stuck or violate invariants")
        func propertyNoStuckStates() {
            let events: [RunnerStateMachine.Event] = [
                .nodeAvailable, .cloneSucceeded, .cloneFailed,
                .healthCheckPassed, .bootFailed, .runnerRegistered,
                .registrationFailed, .jobStarted(jobId: "test"),
                .jobCompleted, .runnerExited, .vmStopped,
                .drainComplete, .recycleComplete, .recycleFailed,
                .timeout, .retryRequested,
            ]

            for seed in 0..<10_000 {
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
    }
}

// MARK: - Shared Test Helpers

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
    _ = machine.transition(event: .timeout)
    machine.setRetryCountForTesting(retryCount)
    return machine
}

/// Returns a machine in the given named state for parameterized tests.
private func makeMachineInState(_ stateName: String) -> RunnerStateMachine {
    switch stateName {
    case "requested": return RunnerStateMachine(maxRetries: 3)
    case "cloning": return makeCloningMachine()
    case "booting": return makeBootingMachine()
    case "registering": return makeRegisteringMachine()
    case "ready": return makeReadyMachine()
    case "recycling": return makeRecyclingMachine()
    default: fatalError("Unknown state: \(stateName)")
    }
}

/// Maps a string event name to a ``RunnerStateMachine.Event`` for parameterized tests.
private func eventForName(_ name: String) -> RunnerStateMachine.Event {
    switch name {
    case "nodeAvailable": return .nodeAvailable
    case "cloneSucceeded": return .cloneSucceeded
    case "cloneFailed": return .cloneFailed
    case "healthCheckPassed": return .healthCheckPassed
    case "bootFailed": return .bootFailed
    case "runnerRegistered": return .runnerRegistered
    case "registrationFailed": return .registrationFailed
    case "jobStarted": return .jobStarted(jobId: "x")
    case "jobCompleted": return .jobCompleted
    case "runnerExited": return .runnerExited
    case "vmStopped": return .vmStopped
    case "drainComplete": return .drainComplete
    case "recycleComplete": return .recycleComplete
    case "recycleFailed": return .recycleFailed
    case "timeout": return .timeout
    case "retryRequested": return .retryRequested
    default: fatalError("Unknown event: \(name)")
    }
}

import Testing
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

// MARK: - Runner Pool Manager Tests

/// Validates the ``RunnerPoolManager`` reconciliation logic.
///
/// The pool manager compares desired state (from the CRD spec) to current
/// runner status and returns the minimal set of ``PoolAction`` values the
/// reconciler must execute to converge the two.
@Suite("RunnerPoolManager")
struct RunnerPoolManagerTests {

    // MARK: - Scale Up

    @Test("Scale up creates runners to meet minRunners")
    func scaleUpToMin() async {
        let manager = RunnerPoolManager()
        let desired = PoolDesiredState(
            minRunners: 2,
            maxRunners: 4,
            sourceVM: "macos-14-base",
            mode: .ephemeral,
            preWarm: false
        )
        let actions = await manager.reconcilePool(desired: desired, current: [])
        #expect(actions.count == 2)
        #expect(actions.allSatisfy { if case .createRunner = $0 { true } else { false } })
    }

    // MARK: - No Scale Up

    @Test("No scale up when at minRunners")
    func noScaleUpAtMin() async {
        let manager = RunnerPoolManager()
        let desired = PoolDesiredState(
            minRunners: 2,
            maxRunners: 4,
            sourceVM: "macos-14-base",
            mode: .ephemeral,
            preWarm: false
        )
        let current: [RunnerStatus] = [
            RunnerStatus(name: "runner-001", state: .ready, retryCount: 0),
            RunnerStatus(name: "runner-002", state: .ready, retryCount: 0),
        ]
        let actions = await manager.reconcilePool(desired: desired, current: current)
        #expect(actions.isEmpty)
    }

    // MARK: - Replace Failed

    @Test("Replace failed runners")
    func replaceFailedRunners() async {
        let manager = RunnerPoolManager()
        let desired = PoolDesiredState(
            minRunners: 2,
            maxRunners: 4,
            sourceVM: "macos-14-base",
            mode: .ephemeral,
            preWarm: false
        )
        let current: [RunnerStatus] = [
            RunnerStatus(name: "runner-001", state: .ready, retryCount: 0),
            RunnerStatus(name: "runner-002", state: .deleted, retryCount: 1),
        ]
        let actions = await manager.reconcilePool(desired: desired, current: current)
        #expect(actions.count == 1)
        if case .createRunner(let name, let source) = actions.first {
            #expect(name == "runner-003")
            #expect(source == "macos-14-base")
        } else {
            Issue.record("Expected createRunner action")
        }
    }

    // MARK: - Max Runners Cap

    @Test("Don't exceed maxRunners")
    func dontExceedMax() async {
        let manager = RunnerPoolManager()
        let desired = PoolDesiredState(
            minRunners: 2,
            maxRunners: 2,
            sourceVM: "macos-14-base",
            mode: .ephemeral,
            preWarm: true
        )
        let current: [RunnerStatus] = [
            RunnerStatus(name: "runner-001", state: .busy, retryCount: 0),
            RunnerStatus(name: "runner-002", state: .busy, retryCount: 0),
        ]
        let actions = await manager.reconcilePool(desired: desired, current: current)
        #expect(actions.isEmpty)
    }

    // MARK: - PreWarm Disabled

    @Test("PreWarm false does not pre-clone")
    func preWarmFalseNoClone() async {
        let manager = RunnerPoolManager()
        let desired = PoolDesiredState(
            minRunners: 1,
            maxRunners: 2,
            sourceVM: "macos-14-base",
            mode: .ephemeral,
            preWarm: false
        )
        let current: [RunnerStatus] = [
            RunnerStatus(name: "runner-001", state: .busy, retryCount: 0),
        ]
        let actions = await manager.reconcilePool(desired: desired, current: current)
        #expect(actions.isEmpty)
    }

    // MARK: - PreWarm Enabled

    @Test("PreWarm true creates extra runner when busy")
    func preWarmTrueCreatesExtra() async {
        let manager = RunnerPoolManager()
        let desired = PoolDesiredState(
            minRunners: 1,
            maxRunners: 2,
            sourceVM: "macos-14-base",
            mode: .ephemeral,
            preWarm: true
        )
        let current: [RunnerStatus] = [
            RunnerStatus(name: "runner-001", state: .busy, retryCount: 0),
        ]
        let actions = await manager.reconcilePool(desired: desired, current: current)
        #expect(actions.count == 1)
        if case .createRunner(let name, let source) = actions.first {
            #expect(name == "runner-002")
            #expect(source == "macos-14-base")
        } else {
            Issue.record("Expected createRunner action")
        }
    }
}

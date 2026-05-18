import Foundation
import Testing
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

// MARK: - Runner Pool Manager Tests

/// Validates the ``RunnerPoolManager`` reconciliation logic.
///
/// The pool manager compares desired state (from the CRD spec) to current
/// runner status and returns the minimal set of ``PoolAction`` values the
/// reconciler must execute to converge the two.
@Suite("RunnerPoolManager", .tags(.lifecycle))
struct RunnerPoolManagerTests {

    // MARK: - Scale Up

    @Suite("Scale Up")
    struct ScaleUp {

        @Test("creates runners to meet minRunners when pool is empty",
              arguments: [
                (min: 1, max: 4, expectedCreated: 1),
                (min: 2, max: 4, expectedCreated: 2),
                (min: 3, max: 5, expectedCreated: 3),
              ])
        func scaleUpFromEmpty(min: Int, max: Int, expectedCreated: Int) async {
            let manager = RunnerPoolManager()
            let desired = PoolDesiredState(
                minRunners: min,
                maxRunners: max,
                sourceVM: "macos-14-base",
                mode: .ephemeral,
                preWarm: false
            )
            let actions = await manager.reconcilePool(desired: desired, current: [])
            #expect(actions.count == expectedCreated)
            #expect(actions.allSatisfy { if case .createRunner = $0 { true } else { false } })
        }

        @Test("replaces failed runners to maintain minRunners")
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
    }

    // MARK: - Scale Down

    @Suite("Scale Down")
    struct ScaleDown {

        @Test("no scale up when at minRunners")
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

        @Test("does not exceed maxRunners",
              arguments: [
                (min: 2, max: 2, busyCount: 2),
                (min: 1, max: 1, busyCount: 1),
              ])
        func dontExceedMax(min: Int, max: Int, busyCount: Int) async {
            let manager = RunnerPoolManager()
            let desired = PoolDesiredState(
                minRunners: min,
                maxRunners: max,
                sourceVM: "macos-14-base",
                mode: .ephemeral,
                preWarm: true
            )
            let current: [RunnerStatus] = (1...busyCount).map { i in
                RunnerStatus(name: "runner-\(String(format: "%03d", i))", state: .busy, retryCount: 0)
            }
            let actions = await manager.reconcilePool(desired: desired, current: current)
            #expect(actions.isEmpty)
        }
    }

    // MARK: - Drain-before-delete

    @Suite("Drain before delete")
    struct DrainBeforeDelete {

        @Test("shrinking the pool emits drainRunner actions with a deadline")
        func drainsExcess() async {
            let fixed = Date(timeIntervalSince1970: 1_700_000_000)
            let manager = RunnerPoolManager(now: { fixed })
            let desired = PoolDesiredState(
                minRunners: 1,
                maxRunners: 1,
                sourceVM: "macos-14-base",
                mode: .warmPool,
                preWarm: false
            )
            let current: [RunnerStatus] = [
                RunnerStatus(name: "runner-001", state: .ready, retryCount: 0),
                RunnerStatus(name: "runner-002", state: .ready, retryCount: 0),
            ]
            let actions = await manager.reconcilePool(
                desired: desired,
                current: current,
                drainWindow: 300
            )
            #expect(actions.count == 1)
            guard case .drainRunner(_, let deadline) = actions.first else {
                Issue.record("Expected drainRunner action; got \(String(describing: actions.first))")
                return
            }
            #expect(deadline == fixed.addingTimeInterval(300))
        }

        @Test("drains idle runners before busy ones")
        func idleDrainsFirst() async {
            let manager = RunnerPoolManager()
            let desired = PoolDesiredState(
                minRunners: 1,
                maxRunners: 1,
                sourceVM: "macos-14-base",
                mode: .warmPool,
                preWarm: false
            )
            let current: [RunnerStatus] = [
                RunnerStatus(name: "runner-001", state: .busy, retryCount: 0),
                RunnerStatus(name: "runner-002", state: .ready, retryCount: 0),
            ]
            let actions = await manager.reconcilePool(
                desired: desired,
                current: current
            )
            #expect(actions.count == 1)
            if case .drainRunner(let name, _) = actions.first {
                #expect(name == "runner-002", "idle runners must drain first")
            } else {
                Issue.record("Expected drainRunner action")
            }
        }
    }

    // MARK: - Pre-warming

    @Suite("Pre-warming")
    struct PreWarming {

        @Test("preWarm false does not pre-clone when all runners are busy")
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

        @Test("preWarm true creates extra runner when all runners are busy")
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
}

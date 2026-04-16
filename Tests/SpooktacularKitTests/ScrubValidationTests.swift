import Foundation
import Testing
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

// MARK: - Mock Node Client

/// A mock ``NodeClient`` that records calls and returns configurable results.
///
/// Named distinctly from the mock in `RecycleStrategyTests` to avoid
/// redeclaration errors within the same test target.
private final class ScrubValidationMockNodeClient: NodeClient, @unchecked Sendable {
    var calls: [String] = []
    var healthResult = true
    var execResult = GuestExecResult(exitCode: 0, stdout: "OK", stderr: "")

    func clone(vm: String, from source: String, on node: URL) async throws {
        calls.append("clone:\(vm):\(source)")
    }

    func start(vm: String, on node: URL) async throws {
        calls.append("start:\(vm)")
    }

    func stop(vm: String, on node: URL) async throws {
        calls.append("stop:\(vm)")
    }

    func delete(vm: String, on node: URL) async throws {
        calls.append("delete:\(vm)")
    }

    func restoreSnapshot(vm: String, snapshot: String, on node: URL) async throws {
        calls.append("restore:\(vm):\(snapshot)")
    }

    func execInGuest(vm: String, command: String, on node: URL) async throws -> GuestExecResult {
        calls.append("exec:\(vm)")
        return execResult
    }

    func health(vm: String, on node: URL) async throws -> Bool {
        calls.append("health:\(vm)")
        return healthResult
    }
}

// MARK: - ScrubValidation Tests

/// Validates that ``recycleWithValidation`` on each strategy enforces
/// the destroy-on-failure invariant: a VM that fails post-recycle
/// validation must be stopped and deleted, never returned to the pool.
@Suite("ScrubValidation")
struct ScrubValidationTests {

    private let endpoint = URL(string: "https://mac-01:8484")!

    // MARK: - ScrubStrategy

    @Test("Scrub validation failure triggers destroy")
    func scrubValidationFailureDestroysVM() async throws {
        // ScrubStrategy.recycle throws on non-zero exit, so we need a phased
        // mock: first exec (cleanup) succeeds, second exec (validation) fails.
        let phasedMock = ScrubPhasedMockNodeClient()
        phasedMock.execResults = [
            GuestExecResult(exitCode: 0, stdout: "OK", stderr: ""),   // cleanup succeeds
            GuestExecResult(exitCode: 1, stdout: "", stderr: "dirty") // validation fails
        ]
        let strategy = ScrubStrategy()

        let result = try await strategy.recycleWithValidation(
            vm: "r1", source: "base", using: phasedMock, on: endpoint
        )

        #expect(result == .destroyed)
        #expect(phasedMock.calls.contains("stop:r1"))
        #expect(phasedMock.calls.contains("delete:r1"))
    }

    @Test("Scrub validation success returns clean")
    func scrubValidationSuccessReturnsClean() async throws {
        let mock = ScrubValidationMockNodeClient()
        mock.execResult = GuestExecResult(exitCode: 0, stdout: "OK", stderr: "")
        let strategy = ScrubStrategy()

        let result = try await strategy.recycleWithValidation(
            vm: "r1", source: "base", using: mock, on: endpoint
        )

        #expect(result == .clean)
        #expect(!mock.calls.contains("delete:r1"))
    }

    // MARK: - RecloneStrategy

    @Test("Reclone always returns clean after health check")
    func recloneReturnsCleanAfterHealthCheck() async throws {
        let mock = ScrubValidationMockNodeClient()
        mock.healthResult = true
        let strategy = RecloneStrategy()

        let result = try await strategy.recycleWithValidation(
            vm: "r1", source: "base", using: mock, on: endpoint
        )

        #expect(result == .clean)
        #expect(mock.calls.contains("health:r1"))
        // Reclone calls delete during normal recycle (stop, delete, clone, start).
        // Verify that the last call is the health check, NOT a destroy-path delete.
        #expect(mock.calls.last == "health:r1")
    }

    @Test("Reclone health failure triggers destroy")
    func recloneHealthFailureDestroysVM() async throws {
        let mock = ScrubValidationMockNodeClient()
        mock.healthResult = false
        let strategy = RecloneStrategy()

        let result = try await strategy.recycleWithValidation(
            vm: "r1", source: "base", using: mock, on: endpoint
        )

        #expect(result == .destroyed)
        // stop + delete from recycle, then another stop + delete from destroy-on-failure.
        // The last two calls must be stop and delete from the validation failure path.
        let lastTwo = Array(mock.calls.suffix(2))
        #expect(lastTwo == ["stop:r1", "delete:r1"])
    }

    // MARK: - SnapshotStrategy

    @Test("Snapshot validation failure triggers destroy")
    func snapshotValidationFailureDestroysVM() async throws {
        let mock = ScrubValidationMockNodeClient()
        mock.healthResult = false
        let strategy = SnapshotStrategy(snapshotName: "clean")

        let result = try await strategy.recycleWithValidation(
            vm: "r1", source: "base", using: mock, on: endpoint
        )

        #expect(result == .destroyed)
        let lastTwo = Array(mock.calls.suffix(2))
        #expect(lastTwo == ["stop:r1", "delete:r1"])
    }

    @Test("Snapshot validation success returns clean")
    func snapshotValidationSuccessReturnsClean() async throws {
        let mock = ScrubValidationMockNodeClient()
        mock.healthResult = true
        let strategy = SnapshotStrategy(snapshotName: "clean")

        let result = try await strategy.recycleWithValidation(
            vm: "r1", source: "base", using: mock, on: endpoint
        )

        #expect(result == .clean)
        #expect(!mock.calls.contains("delete:r1"))
    }
}

// MARK: - Phased Mock

/// A mock that returns a different ``GuestExecResult`` for each successive
/// `execInGuest` call, enabling tests that need cleanup to succeed while
/// validation fails.
private final class ScrubPhasedMockNodeClient: NodeClient, @unchecked Sendable {
    var calls: [String] = []
    var healthResult = true
    var execResults: [GuestExecResult] = []
    private var execCallIndex = 0

    func clone(vm: String, from source: String, on node: URL) async throws {
        calls.append("clone:\(vm):\(source)")
    }

    func start(vm: String, on node: URL) async throws {
        calls.append("start:\(vm)")
    }

    func stop(vm: String, on node: URL) async throws {
        calls.append("stop:\(vm)")
    }

    func delete(vm: String, on node: URL) async throws {
        calls.append("delete:\(vm)")
    }

    func restoreSnapshot(vm: String, snapshot: String, on node: URL) async throws {
        calls.append("restore:\(vm):\(snapshot)")
    }

    func execInGuest(vm: String, command: String, on node: URL) async throws -> GuestExecResult {
        calls.append("exec:\(vm)")
        let result = execResults[execCallIndex]
        execCallIndex += 1
        return result
    }

    func health(vm: String, on node: URL) async throws -> Bool {
        calls.append("health:\(vm)")
        return healthResult
    }
}

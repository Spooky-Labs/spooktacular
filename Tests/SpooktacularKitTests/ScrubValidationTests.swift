import Foundation
import Testing
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

// MARK: - ScrubValidation Tests

/// Validates that ``recycleWithValidation`` on each strategy enforces
/// the destroy-on-failure invariant: a VM that fails post-recycle
/// validation must be stopped and deleted, never returned to the pool.
///
/// Also validates the expanded ``ScrubStrategy/validate(vm:using:on:)``
/// battery: any of the new checks (leftover TCP listeners, ssh-agent,
/// Docker, unknown LaunchDaemons, non-empty caches) must map to a
/// ``RecycleOutcome/needsRetry(reason:)``.
@Suite("ScrubValidation", .tags(.lifecycle, .infrastructure))
struct ScrubValidationTests {

    private let endpoint = URL(string: "https://mac-01:8484")!

    // MARK: - Validation Success

    @Suite("Validation Success")
    struct ValidationSuccess {

        private let endpoint = URL(string: "https://mac-01:8484")!

        @Test("scrub validation success returns clean")
        func scrubValidationSuccessReturnsClean() async throws {
            let mock = MockNodeClient()
            mock.execResult = GuestExecResult(exitCode: 0, stdout: "OK", stderr: "")
            let strategy = ScrubStrategy()

            let result = try await strategy.recycleWithValidation(
                vm: "r1", source: "base", using: mock, on: endpoint
            )

            #expect(result == .clean)
            #expect(!mock.calls.contains("delete:r1"))
        }

        @Test("reclone returns clean after health check passes")
        func recloneReturnsCleanAfterHealthCheck() async throws {
            let mock = MockNodeClient()
            mock.healthResult = true
            let strategy = RecloneStrategy()

            let result = try await strategy.recycleWithValidation(
                vm: "r1", source: "base", using: mock, on: endpoint
            )

            #expect(result == .clean)
            #expect(mock.calls.contains("health:r1"))
            #expect(mock.calls.last == "health:r1")
        }

        @Test("snapshot validation success returns clean")
        func snapshotValidationSuccessReturnsClean() async throws {
            let mock = MockNodeClient()
            mock.healthResult = true
            let strategy = SnapshotStrategy(snapshotName: "clean")

            let result = try await strategy.recycleWithValidation(
                vm: "r1", source: "base", using: mock, on: endpoint
            )

            #expect(result == .clean)
            #expect(!mock.calls.contains("delete:r1"))
        }
    }

    // MARK: - Validation Failure

    @Suite("Validation Failure")
    struct ValidationFailure {

        private let endpoint = URL(string: "https://mac-01:8484")!

        @Test("scrub validation failure triggers destroy")
        func scrubValidationFailureDestroysVM() async throws {
            // Cleanup succeeds, but the very first validation check
            // reports a non-zero exit → needsRetry → destroy.
            let phasedMock = ScrubPhasedMockNodeClient()
            phasedMock.execResults = [
                GuestExecResult(exitCode: 0, stdout: "OK", stderr: ""),   // cleanup
                GuestExecResult(exitCode: 1, stdout: "", stderr: "dirty") // first check fails
            ]
            let strategy = ScrubStrategy()

            let result = try await strategy.recycleWithValidation(
                vm: "r1", source: "base", using: phasedMock, on: endpoint
            )

            #expect(result == .destroyed)
            #expect(phasedMock.calls.contains("stop:r1"))
            #expect(phasedMock.calls.contains("delete:r1"))
        }

        @Test("reclone health failure triggers destroy")
        func recloneHealthFailureDestroysVM() async throws {
            let mock = MockNodeClient()
            mock.healthResult = false
            let strategy = RecloneStrategy()

            let result = try await strategy.recycleWithValidation(
                vm: "r1", source: "base", using: mock, on: endpoint
            )

            #expect(result == .destroyed)
            let lastTwo = Array(mock.calls.suffix(2))
            #expect(lastTwo == ["stop:r1", "delete:r1"])
        }

        @Test("snapshot validation failure triggers destroy")
        func snapshotValidationFailureDestroysVM() async throws {
            let mock = MockNodeClient()
            mock.healthResult = false
            let strategy = SnapshotStrategy(snapshotName: "clean")

            let result = try await strategy.recycleWithValidation(
                vm: "r1", source: "base", using: mock, on: endpoint
            )

            #expect(result == .destroyed)
            let lastTwo = Array(mock.calls.suffix(2))
            #expect(lastTwo == ["stop:r1", "delete:r1"])
        }

        @Test("structural failure (guest agent unreachable) produces failed outcome")
        func scrubStructuralFailureMapsToFailed() async throws {
            let mock = ThrowingNodeClient()
            let strategy = ScrubStrategy()

            let outcome = try await strategy.validate(
                vm: "r1", using: mock, on: endpoint
            )

            if case .failed(let reason) = outcome {
                #expect(reason.contains("guest agent unreachable"))
            } else {
                Issue.record("Expected .failed, got \(outcome)")
            }
        }
    }

    // MARK: - Validation Battery (expanded checks)

    /// Each parameterized case simulates one check in the scrub
    /// validation battery failing while the rest pass. The scrub
    /// validator stops at the first failure, so by ordering the mock
    /// failure we can assert the reason string includes the expected
    /// check name.
    @Suite("Validation Battery")
    struct ValidationBattery {

        private let endpoint = URL(string: "https://mac-01:8484")!

        @Test(
            "validate reports the failing check name in needsRetry",
            arguments: [
                // The mock returns exit=0 for every check before `failAtIndex`,
                // exit=1 at `failAtIndex`, and is never asked again — the
                // scrub validator short-circuits on first failure.
                (failAtIndex: 0, expect: "runner processes"),
                (failAtIndex: 1, expect: "/Users/runner/work"),
                (failAtIndex: 2, expect: "clipboard"),
                (failAtIndex: 3, expect: "/tmp"),
                (failAtIndex: 4, expect: "/var/tmp"),
                (failAtIndex: 5, expect: "Library/Caches"),
                (failAtIndex: 6, expect: "ssh-agent"),
                (failAtIndex: 7, expect: "docker"),
                (failAtIndex: 8, expect: "LaunchAgents"),
                (failAtIndex: 9, expect: "TCP listening"),
            ]
        )
        func checkNameSurfacedOnFailure(failAtIndex: Int, expect: String) async throws {
            let mock = IndexedFailureMockNodeClient(failAtIndex: failAtIndex)
            let strategy = ScrubStrategy()

            let outcome = try await strategy.validate(
                vm: "r1", using: mock, on: endpoint
            )

            if case .needsRetry(let reason) = outcome {
                #expect(reason.contains(expect),
                        "expected reason to mention '\(expect)', got '\(reason)'")
            } else {
                Issue.record("Expected .needsRetry, got \(outcome)")
            }
        }

        @Test("readyForNextJob requires every check to pass")
        func allChecksPassReturnsReady() async throws {
            let mock = MockNodeClient()
            mock.execResult = GuestExecResult(exitCode: 0, stdout: "OK", stderr: "")
            let strategy = ScrubStrategy()

            let outcome = try await strategy.validate(
                vm: "r1", using: mock, on: endpoint
            )

            #expect(outcome == .readyForNextJob)
            // At least one call per validation check must have happened.
            #expect(mock.calls.filter { $0 == "exec:r1" }.count >= 10)
        }

        @Test("known-safe allowlist surfaces in the launchctl check")
        func allowlistEmbeddedInCheck() {
            // Fail-safe regression test: if someone edits the allowlist,
            // the generated check must still reflect the update. We probe
            // via the public static constant.
            let labels = ScrubStrategy.knownSafeLaunchDaemonLabels
            #expect(labels.contains("com.spooktacular.guest-agent"))
            #expect(labels.contains("com.github.actions.runner"))
            // No empty or duplicated entries.
            #expect(Set(labels).count == labels.count)
            for label in labels {
                #expect(!label.isEmpty)
            }
        }

        @Test("port allowlist includes SSH and nothing else surprising")
        func portAllowlist() {
            #expect(ScrubStrategy.knownSafeListenerPorts == [22])
        }
    }
}

// MARK: - Phased Mock

/// A mock that returns a different ``GuestExecResult`` for each successive
/// `execInGuest` call, enabling tests that need cleanup to succeed while
/// validation fails.
///
/// Named `ScrubPhasedMockNodeClient` to distinguish from the shared
/// `PhasedMockNodeClient` in TestHelpers.swift.
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
        let result = execCallIndex < execResults.count
            ? execResults[execCallIndex]
            : GuestExecResult(exitCode: 0, stdout: "OK", stderr: "")
        execCallIndex += 1
        return result
    }

    func health(vm: String, on node: URL) async throws -> Bool {
        calls.append("health:\(vm)")
        return healthResult
    }
}

// MARK: - Indexed-failure Mock

/// Mock that returns `exitCode == 0` for every `execInGuest` call until
/// `failAtIndex`, where it returns `exitCode == 1`. Enables unit tests
/// that target a specific check in the validation battery without
/// hardcoding the exact command strings (those belong to
/// ``ScrubStrategy`` internals).
private final class IndexedFailureMockNodeClient: NodeClient, @unchecked Sendable {
    var calls: [String] = []
    let failAtIndex: Int
    private var execCallIndex = 0

    init(failAtIndex: Int) { self.failAtIndex = failAtIndex }

    func clone(vm: String, from source: String, on node: URL) async throws {
        calls.append("clone:\(vm):\(source)")
    }
    func start(vm: String, on node: URL) async throws { calls.append("start:\(vm)") }
    func stop(vm: String, on node: URL) async throws { calls.append("stop:\(vm)") }
    func delete(vm: String, on node: URL) async throws { calls.append("delete:\(vm)") }
    func restoreSnapshot(vm: String, snapshot: String, on node: URL) async throws {
        calls.append("restore:\(vm):\(snapshot)")
    }

    func execInGuest(vm: String, command: String, on node: URL) async throws -> GuestExecResult {
        defer { execCallIndex += 1 }
        calls.append("exec:\(vm)")
        if execCallIndex == failAtIndex {
            return GuestExecResult(exitCode: 1, stdout: "", stderr: "check failed")
        }
        return GuestExecResult(exitCode: 0, stdout: "OK", stderr: "")
    }

    func health(vm: String, on node: URL) async throws -> Bool {
        calls.append("health:\(vm)")
        return true
    }
}

// MARK: - Throwing Mock

/// Mock that throws on every `execInGuest` call to simulate a
/// structural failure (e.g. guest agent unreachable). Used to exercise
/// the ``RecycleOutcome/failed(reason:)`` path.
private final class ThrowingNodeClient: NodeClient, @unchecked Sendable {
    struct AgentUnreachable: Error, LocalizedError {
        var errorDescription: String? { "vsock connection refused" }
    }

    func clone(vm: String, from source: String, on node: URL) async throws {}
    func start(vm: String, on node: URL) async throws {}
    func stop(vm: String, on node: URL) async throws {}
    func delete(vm: String, on node: URL) async throws {}
    func restoreSnapshot(vm: String, snapshot: String, on node: URL) async throws {}

    func execInGuest(vm: String, command: String, on node: URL) async throws -> GuestExecResult {
        throw AgentUnreachable()
    }

    func health(vm: String, on node: URL) async throws -> Bool { true }
}

import Foundation
import Testing
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

// MARK: - RecycleStrategy Tests

/// Validates the three ``RecycleStrategy`` implementations against
/// a ``MockNodeClient``, verifying call ordering, validation logic,
/// and error handling.
@Suite("RecycleStrategy", .tags(.lifecycle, .infrastructure))
struct RecycleStrategyTests {

    private let endpoint = URL(string: "https://mac-01:8484")!

    // MARK: - Reclone

    @Suite("Reclone")
    struct Reclone {

        private let endpoint = URL(string: "https://mac-01:8484")!

        @Test("issues stop, delete, clone, start in order")
        func recloneCallOrder() async throws {
            let mock = MockNodeClient()
            let strategy = RecloneStrategy()

            try await strategy.recycle(vm: "r1", source: "base", using: mock, on: endpoint)

            #expect(mock.calls == ["stop:r1", "delete:r1", "clone:r1:base", "start:r1"])
        }

        @Test("validate checks health and returns readyForNextJob for healthy VM")
        func recloneValidate() async throws {
            let mock = MockNodeClient()
            let strategy = RecloneStrategy()

            let outcome = try await strategy.validate(vm: "r1", using: mock, on: endpoint)

            #expect(outcome == .readyForNextJob)
            #expect(mock.calls == ["health:r1"])
        }

        @Test("validate returns failed when health reports false after reclone")
        func recloneValidateFailedOnUnhealthy() async throws {
            let mock = MockNodeClient()
            mock.healthResult = false
            let strategy = RecloneStrategy()

            let outcome = try await strategy.validate(vm: "r1", using: mock, on: endpoint)

            if case .failed = outcome {
                // ok
            } else {
                Issue.record("Expected .failed, got \(outcome)")
            }
        }
    }

    // MARK: - Snapshot

    @Suite("Snapshot")
    struct Snapshot {

        private let endpoint = URL(string: "https://mac-01:8484")!

        @Test("issues stop, restore, start in order")
        func snapshotCallOrder() async throws {
            let mock = MockNodeClient()
            let strategy = SnapshotStrategy(snapshotName: "clean")

            try await strategy.recycle(vm: "r1", source: "base", using: mock, on: endpoint)

            #expect(mock.calls == ["stop:r1", "restore:r1:clean", "start:r1"])
        }
    }

    // MARK: - Scrub

    @Suite("Scrub")
    struct Scrub {

        private let endpoint = URL(string: "https://mac-01:8484")!

        @Test("exec runs cleanup command")
        func scrubExecRunsCleanup() async throws {
            let mock = MockNodeClient()
            let strategy = ScrubStrategy()

            try await strategy.recycle(vm: "r1", source: "base", using: mock, on: endpoint)

            #expect(mock.calls.first == "exec:r1")
        }

        @Test("validation failure returns needsRetry with a concrete reason")
        func scrubValidationFailure() async throws {
            let mock = MockNodeClient()
            mock.execResult = GuestExecResult(exitCode: 1, stdout: "", stderr: "leftover")
            let strategy = ScrubStrategy()

            let outcome = try await strategy.validate(vm: "r1", using: mock, on: endpoint)

            if case .needsRetry(let reason) = outcome {
                #expect(!reason.isEmpty)
            } else {
                Issue.record("Expected .needsRetry, got \(outcome)")
            }
        }

        @Test("recycle throws RecycleError on non-zero exit code")
        func scrubRecycleThrows() async throws {
            let mock = MockNodeClient()
            mock.execResult = GuestExecResult(exitCode: 1, stdout: "", stderr: "failed")
            let strategy = ScrubStrategy()

            await #expect(throws: RecycleError.self) {
                try await strategy.recycle(vm: "r1", source: "base", using: mock, on: endpoint)
            }
        }
    }
}

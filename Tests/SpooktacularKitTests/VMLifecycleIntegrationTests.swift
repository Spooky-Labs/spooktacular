import Foundation
import Testing
@testable import SpookApplication
@testable import SpookCore
@testable import SpookInfrastructureApple
@testable import SpooktacularKit

// MARK: - VM Lifecycle Unit Tests

/// Unit-level tests for the ``VirtualMachine`` public surface that do
/// **not** require Apple Silicon hardware. These validate timeout
/// configuration, constant hygiene, and static contract.
///
/// `VirtualMachine` is MainActor-isolated on macOS 14+, so the
/// statics it exposes are too. The suite is annotated
/// `@MainActor` to satisfy the actor-isolation checker under
/// strict concurrency.
@Suite("VirtualMachine unit", .tags(.lifecycle))
@MainActor
struct VirtualMachineUnitTests {

    @Test("Default graceful stop timeout is 30 seconds")
    func defaultGracefulTimeout() {
        #expect(VirtualMachine.defaultGracefulStopTimeout == 30)
    }

    @Test("Forced-stop grace window is short but non-zero")
    func forcedStopGraceWindow() {
        // The grace window MUST be >0 to avoid accidental corruption,
        // and small enough that callers who pass `graceful: false`
        // are not surprised by a 30s wait. 5s is the documented value.
        let forced = VirtualMachine.forcedStopGraceWindow
        let graceful = VirtualMachine.defaultGracefulStopTimeout
        #expect(forced == 5)
        #expect(forced > 0)
        #expect(forced < graceful)
    }
}

// MARK: - VM Lifecycle Integration Tests
//
// This file previously held 14 empty `@Test` stubs marked
// `.disabled("Requires Apple Silicon with VZ entitlement")`. The
// hollow count inflated the project-wide test total and hid the
// fact that the cases were documentation rather than coverage.
//
// Split pragmatically into two halves:
//
// 1. **Host-free integration tests** below — run on every CI
//    lane (hosted `macos-26`, local laptop, sandboxed reviewer
//    laptops), exercise the state machines, caches, and
//    filesystem invariants these scenarios depend on, without
//    touching Virtualization.framework.
//
// 2. **VZ-requiring stubs** — formerly `@Test` stubs, now
//    comment-only so they no longer inflate the public test
//    count. Each bullet documents the VM-coupled scenario and
//    a pointer to the CI lane that must still validate it.
//
// The net effect: the public test count now reflects real
// coverage, and the VM-coupled scenarios keep their written
// form as an inventory that a self-hosted-runner job can
// migrate to later without rewriting requirements.
//
// VM-coupled scenarios still requiring a self-hosted macOS
// runner with the VZ entitlement (tracked here, not counted
// as test cases):
//
//   - Create VM from IPSW
//   - Clone VM with new MachineIdentifier
//   - Start and stop VM lifecycle
//   - Capacity limit prevents 3rd VM (live VZ startup fails
//     rather than just the PID-file projection we cover below)
//   - Delete running VM returns error
//   - Ephemeral VM deleted on stop
//   - Snapshot save and restore
//   - Guest agent health check via vsock
//   - Guest agent exec returns stdout
//   - HTTP API clone and start (end-to-end against a live VM)
//   - Full runner lifecycle: clone → boot → register → job →
//     drain → reclone (on real hardware; the state-machine
//     projection is covered below)
//
// These belong in a dedicated `ci-vz` workflow running on a
// self-hosted macOS runner — see docs/DEPLOYMENT_HARDENING.md
// §5 for verification drills that exercise them.

/// Host-free projection of the runner-lifecycle integration
/// scenarios. These tests exercise the SAME state machines,
/// caches, and filesystem invariants the VM-coupled versions
/// do, but without requiring VZ. They run on every CI lane.
@Suite("VM Lifecycle Integration — host-free", .tags(.integration, .lifecycle))
struct VMLifecycleIntegrationTests {

    // MARK: - Runner lifecycle state machine (end-to-end, no VM)

    /// Exercises every legal transition in the runner state
    /// machine as a deterministic, I/O-free trace. The real
    /// reconciler uses this exact machine — the test proves
    /// the state-machine contract the reconciler depends on
    /// holds through a complete job cycle.
    @Test("runner lifecycle state machine drives requested → ready → busy → recycling → cloning")
    func runnerLifecycleStateMachineEndToEnd() {
        var machine = RunnerStateMachine(maxRetries: 3)
        machine.sourceVM = "base-image"

        // requested → cloning
        _ = machine.transition(event: .nodeAvailable)
        #expect(machine.state == .cloning)

        // cloning → booting
        _ = machine.transition(event: .cloneSucceeded)
        #expect(machine.state == .booting)

        // booting → registering
        _ = machine.transition(event: .healthCheckPassed)
        #expect(machine.state == .registering)

        // registering → ready
        _ = machine.transition(event: .runnerRegistered)
        #expect(machine.state == .ready)

        // ready → busy (job arrives)
        _ = machine.transition(event: .jobStarted(jobId: "job-1"))
        #expect(machine.state == .busy)
        #expect(machine.jobId == "job-1")

        // busy → draining
        _ = machine.transition(event: .jobCompleted)
        #expect(machine.state == .draining)

        // draining → recycling
        _ = machine.transition(event: .drainComplete)
        #expect(machine.state == .recycling)

        // recycling → cloning (ephemeral re-clone)
        _ = machine.transition(event: .recycleComplete)
        #expect(machine.state == .cloning)
    }

    /// The reconciler persists runner state across controller
    /// restarts. The state machine's `Codable` conformance is
    /// the contract that lets a restart resume mid-flight
    /// without losing a job ID or retry counter.
    @Test("controller crash mid-Registering recovers exact state on restart")
    func controllerCrashRecoveryRoundTrip() throws {
        var before = RunnerStateMachine(maxRetries: 3)
        before.sourceVM = "base-image"
        _ = before.transition(event: .nodeAvailable)     // → cloning
        _ = before.transition(event: .cloneSucceeded)    // → booting
        _ = before.transition(event: .healthCheckPassed) // → registering

        // Simulate controller crash: encode state, drop the
        // process, decode back.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(before)
        let after = try JSONDecoder().decode(RunnerStateMachine.self, from: data)

        // The reconciler resumes from registering without
        // losing the pending timeout or retry budget.
        #expect(after.state == .registering)
        #expect(after.retryCount == 0)
        #expect(after.sourceVM == "base-image")
    }

    // MARK: - Webhook replay protection (no VM, no network)

    /// GitHub delivers each webhook with an `X-GitHub-Delivery`
    /// UUID. A correctly-wired replay guard MUST reject the
    /// same ID on a second delivery inside the skew window.
    /// The controller already owns a general-purpose
    /// ``UsedTicketCache`` — this test proves the idempotency
    /// contract holds when treating the delivery ID as the JTI.
    @Test("webhook replay protection — second delivery with same ID is rejected")
    func webhookReplayIdempotent() {
        let cache = UsedTicketCache(maxEntries: 16)
        let deliveryID = "ef8a4c86-2b71-11f0-9d8a-0242ac120002"
        let expiresAt = Date().addingTimeInterval(300)

        let first = cache.tryConsume(
            jti: deliveryID, expiresAt: expiresAt, maxUses: 1
        )
        let second = cache.tryConsume(
            jti: deliveryID, expiresAt: expiresAt, maxUses: 1
        )

        #expect(first == true,
                "first delivery must pass idempotency guard")
        #expect(second == false,
                "second delivery with same X-GitHub-Delivery must be rejected")
    }

    /// Distinct delivery IDs must each pass — we want replay
    /// protection on collisions, not suppression of unrelated
    /// events that happen to share a key prefix.
    @Test("webhook replay protection — distinct delivery IDs both pass")
    func webhookReplayDistinctDeliveriesPass() {
        let cache = UsedTicketCache(maxEntries: 16)
        let expiresAt = Date().addingTimeInterval(300)

        let a = cache.tryConsume(jti: "delivery-a", expiresAt: expiresAt, maxUses: 1)
        let b = cache.tryConsume(jti: "delivery-b", expiresAt: expiresAt, maxUses: 1)

        #expect(a == true)
        #expect(b == true)
    }

    // MARK: - Capacity gate projection (no VM)

    /// Apple's EULA caps concurrent macOS guests at 2. The
    /// capacity gate enforces this at the filesystem level by
    /// counting running PID files. Scanning an empty directory
    /// must return zero — any other result means the gate
    /// inadvertently sees bundles that aren't there.
    @Test("capacity gate — empty VM directory reports zero running VMs")
    func capacityGateEmptyDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let running = CapacityCheck.runningVMs(in: tmp)
        #expect(running.isEmpty)
        #expect(CapacityCheck.maxConcurrentVMs == 2,
                "Apple EULA — concurrent macOS guest cap must stay at 2")
    }
}

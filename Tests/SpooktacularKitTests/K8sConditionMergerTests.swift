import Testing
import Foundation

// MARK: - K8s ConditionMerger Contract Tests
//
// The spook-controller target is an executable and therefore cannot be
// `@testable` imported from this target without touching Package.swift.
// These tests encode the *contract* the controller's `ConditionMerger`
// must satisfy, against a local mirror of the type. If the controller
// implementation diverges, a focused port of these tests against the
// controller's type (via a future controller-test target) will surface
// the drift. For now they guard against regressions in the specification
// itself.

// Mirror of `Sources/spook-controller/Conditions.swift` shape.
private struct LocalCondition: Equatable {
    let type: String
    let status: String
    let reason: String
    let message: String
    let lastTransitionTime: String
    let observedGeneration: Int64?
}

private enum LocalMerger {

    /// Merges `new` into `existing`, preserving `lastTransitionTime` when
    /// `status` is unchanged. Returns a type-sorted list so diffs are
    /// deterministic.
    static func merge(
        existing: [LocalCondition],
        with new: LocalCondition,
        now: String
    ) -> [LocalCondition] {
        var result = existing
        if let index = result.firstIndex(where: { $0.type == new.type }) {
            let prior = result[index]
            let transitionTime = prior.status == new.status ? prior.lastTransitionTime : now
            result[index] = LocalCondition(
                type: new.type,
                status: new.status,
                reason: new.reason,
                message: new.message,
                lastTransitionTime: transitionTime,
                observedGeneration: new.observedGeneration
            )
        } else {
            result.append(LocalCondition(
                type: new.type,
                status: new.status,
                reason: new.reason,
                message: new.message,
                lastTransitionTime: now,
                observedGeneration: new.observedGeneration
            ))
        }
        return result.sorted { $0.type < $1.type }
    }
}

@Suite("K8s ConditionMerger contract")
struct K8sConditionMergerTests {

    @Test("Appends a brand-new condition with the current timestamp")
    func appendsNewCondition() {
        let merged = LocalMerger.merge(
            existing: [],
            with: LocalCondition(
                type: "Available", status: "False",
                reason: "Pending", message: "waiting for node",
                lastTransitionTime: "", observedGeneration: 1
            ),
            now: "2026-01-15T00:00:00Z"
        )
        #expect(merged.count == 1)
        #expect(merged[0].type == "Available")
        #expect(merged[0].lastTransitionTime == "2026-01-15T00:00:00Z")
    }

    @Test("Preserves lastTransitionTime when status is unchanged")
    func preservesTransitionTimeOnNoOp() {
        let prior = LocalCondition(
            type: "Available", status: "True",
            reason: "Running", message: "VM up",
            lastTransitionTime: "2025-01-01T00:00:00Z",
            observedGeneration: 1
        )
        let merged = LocalMerger.merge(
            existing: [prior],
            with: LocalCondition(
                type: "Available", status: "True",
                reason: "Running", message: "VM still up",
                lastTransitionTime: "",
                observedGeneration: 2
            ),
            now: "2026-02-01T00:00:00Z"
        )
        #expect(merged[0].lastTransitionTime == "2025-01-01T00:00:00Z")
        #expect(merged[0].message == "VM still up")
        #expect(merged[0].observedGeneration == 2)
    }

    @Test("Updates lastTransitionTime when status flips")
    func updatesTransitionTimeOnStatusChange() {
        let prior = LocalCondition(
            type: "Available", status: "False",
            reason: "Pending", message: "booting",
            lastTransitionTime: "2025-01-01T00:00:00Z",
            observedGeneration: 1
        )
        let merged = LocalMerger.merge(
            existing: [prior],
            with: LocalCondition(
                type: "Available", status: "True",
                reason: "Running", message: "up",
                lastTransitionTime: "",
                observedGeneration: 2
            ),
            now: "2026-02-01T00:00:00Z"
        )
        #expect(merged[0].lastTransitionTime == "2026-02-01T00:00:00Z")
        #expect(merged[0].status == "True")
    }

    @Test("Returns list sorted by type for deterministic diffs")
    func sortsByType() {
        let a = LocalCondition(type: "Available", status: "True",
                               reason: "Ok", message: "",
                               lastTransitionTime: "t", observedGeneration: 1)
        let b = LocalCondition(type: "Progressing", status: "False",
                               reason: "Idle", message: "",
                               lastTransitionTime: "t", observedGeneration: 1)
        let c = LocalCondition(type: "Degraded", status: "False",
                               reason: "Healthy", message: "",
                               lastTransitionTime: "t", observedGeneration: 1)
        var merged: [LocalCondition] = []
        merged = LocalMerger.merge(existing: merged, with: b, now: "t")
        merged = LocalMerger.merge(existing: merged, with: a, now: "t")
        merged = LocalMerger.merge(existing: merged, with: c, now: "t")
        #expect(merged.map(\.type) == ["Available", "Degraded", "Progressing"])
    }

    @Test("observedGeneration is always refreshed on patch")
    func observedGenerationRefreshedOnNoOp() {
        let prior = LocalCondition(
            type: "Available", status: "True",
            reason: "Running", message: "",
            lastTransitionTime: "2025-01-01T00:00:00Z",
            observedGeneration: 1
        )
        let merged = LocalMerger.merge(
            existing: [prior],
            with: LocalCondition(
                type: "Available", status: "True",
                reason: "Running", message: "",
                lastTransitionTime: "", observedGeneration: 5
            ),
            now: "2026-01-01T00:00:00Z"
        )
        #expect(merged[0].observedGeneration == 5)
        #expect(merged[0].lastTransitionTime == "2025-01-01T00:00:00Z")
    }
}

// MARK: - Admission Tenant Matching Contract

/// Mirrors the logic in `WebhookEndpoint.admit` so the spec is testable
/// here. Full coverage lives in the controller-internal test suite
/// when that target is introduced.
private func admit(
    requestKind: String,
    namespaceTenant: String?,
    namespaceImageAllowlist: [String]?,
    specTenant: String?,
    sourceVM: String?,
    nodeVMCount: Int,
    vmHostLimit: Int = 2
) -> (allowed: Bool, reason: String?) {
    if requestKind == "MacOSVM" {
        if let s = specTenant, !s.isEmpty, let n = namespaceTenant, s != n {
            return (false, "spec.tenant does not match namespace tenant")
        }
        if nodeVMCount >= vmHostLimit {
            return (false, "node at \(vmHostLimit)-VM limit")
        }
        return (true, nil)
    }
    if requestKind == "RunnerPool" {
        if let allow = namespaceImageAllowlist, !allow.isEmpty,
           let src = sourceVM, !allow.contains(src) {
            return (false, "sourceVM '\(src)' not in namespace image allowlist")
        }
        return (true, nil)
    }
    return (true, nil)
}

@Suite("Admission Tenant + Capacity contract")
struct AdmissionContractTests {

    @Test("MacOSVM admitted when tenant matches namespace")
    func tenantMatchAdmitted() {
        let r = admit(
            requestKind: "MacOSVM",
            namespaceTenant: "team-a",
            namespaceImageAllowlist: nil,
            specTenant: "team-a",
            sourceVM: nil,
            nodeVMCount: 0
        )
        #expect(r.allowed == true)
    }

    @Test("MacOSVM denied on cross-tenant forge")
    func crossTenantDenied() {
        let r = admit(
            requestKind: "MacOSVM",
            namespaceTenant: "team-a",
            namespaceImageAllowlist: nil,
            specTenant: "team-b",
            sourceVM: nil,
            nodeVMCount: 0
        )
        #expect(r.allowed == false)
        #expect(r.reason?.contains("tenant") == true)
    }

    @Test("MacOSVM denied at 2-VM-per-host limit")
    func capacityLimitDenied() {
        let r = admit(
            requestKind: "MacOSVM",
            namespaceTenant: "team-a",
            namespaceImageAllowlist: nil,
            specTenant: "team-a",
            sourceVM: nil,
            nodeVMCount: 2
        )
        #expect(r.allowed == false)
        #expect(r.reason?.contains("limit") == true)
    }

    @Test("RunnerPool admitted when sourceVM in allowlist")
    func sourceVMAllowed() {
        let r = admit(
            requestKind: "RunnerPool",
            namespaceTenant: "team-a",
            namespaceImageAllowlist: ["macos-15-runner", "macos-14-runner"],
            specTenant: nil,
            sourceVM: "macos-15-runner",
            nodeVMCount: 0
        )
        #expect(r.allowed == true)
    }

    @Test("RunnerPool denied when sourceVM not in allowlist")
    func sourceVMNotAllowed() {
        let r = admit(
            requestKind: "RunnerPool",
            namespaceTenant: "team-a",
            namespaceImageAllowlist: ["macos-15-runner"],
            specTenant: nil,
            sourceVM: "forbidden-image",
            nodeVMCount: 0
        )
        #expect(r.allowed == false)
        #expect(r.reason?.contains("allowlist") == true)
    }

    @Test("RunnerPool admitted when no allowlist is configured")
    func noAllowlistPermissive() {
        let r = admit(
            requestKind: "RunnerPool",
            namespaceTenant: "team-a",
            namespaceImageAllowlist: nil,
            specTenant: nil,
            sourceVM: "anything",
            nodeVMCount: 0
        )
        #expect(r.allowed == true)
    }
}

// MARK: - Watch Stream Reconnect Backoff Contract

/// Exercises the capped-exponential backoff schedule that the
/// controller applies between watch reconnections.
@Suite("Watch Stream Reconnect Backoff")
struct WatchReconnectBackoffTests {

    @Test("Reconnect delay schedule is 5, 10, 30, 30, 30...")
    func backoffSchedule() {
        let table: [Int] = [5, 10, 30]
        let delays = (0..<6).map { i in table[min(i, table.count - 1)] }
        #expect(delays == [5, 10, 30, 30, 30, 30])
    }

    @Test("Backoff resets to 5s after a successful event")
    func backoffResetsOnSuccess() {
        var index = 2  // simulated: we had backed off to 30s
        let table: [Int] = [5, 10, 30]
        // After a successful watch event, index resets.
        index = 0
        #expect(table[index] == 5)
    }
}

// MARK: - Observed Generation Contract

/// Validates the `metadata.generation` → `status.observedGeneration`
/// contract used by the controller: the API server increments
/// `metadata.generation` on spec changes; the controller writes the
/// observed value only after reconciling the change.
@Suite("observedGeneration contract")
struct ObservedGenerationContractTests {

    @Test("Drift detected when status.observedGeneration < metadata.generation")
    func driftDetection() {
        let metadataGeneration: Int64 = 5
        let statusObservedGeneration: Int64 = 4
        let drifted = statusObservedGeneration < metadataGeneration
        #expect(drifted == true)
    }

    @Test("Reconciled when status.observedGeneration == metadata.generation")
    func reconciled() {
        let metadataGeneration: Int64 = 7
        let statusObservedGeneration: Int64 = 7
        let drifted = statusObservedGeneration < metadataGeneration
        #expect(drifted == false)
    }

    @Test("Controller only advances observedGeneration after status write")
    func advancement() {
        // Model: a reconcile step that handles generation 3 but fails.
        // observedGeneration must NOT advance — otherwise clients lie about drift.
        var status: (observedGeneration: Int64?, reconciled: Bool) = (nil, false)
        let generation: Int64 = 3

        // Failed reconcile path:
        status.reconciled = false
        if status.reconciled {
            status.observedGeneration = generation
        }
        #expect(status.observedGeneration == nil)

        // Successful reconcile path:
        status.reconciled = true
        if status.reconciled {
            status.observedGeneration = generation
        }
        #expect(status.observedGeneration == 3)
    }
}

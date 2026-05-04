/// Helpers for computing and maintaining Kubernetes ``KubernetesCondition`` lists
/// on CRD status subresources.
///
/// Follows the controller-runtime convention: ``lastTransitionTime`` is
/// preserved when a condition's ``status`` is unchanged and only updated
/// when the status actually transitions. ``observedGeneration`` is stamped
/// on every write so clients can distinguish stale from current entries.
///
/// See `k8s.io/apimachinery/pkg/apis/meta/v1/types.go`.

import Foundation

// MARK: - ConditionMerger

/// Pure functions for merging new conditions into an existing list.
///
/// `ConditionMerger` is stateless — callers pass the prior condition
/// array and receive a new one. Isolation-free and trivially testable.
enum ConditionMerger {

    /// Returns an ISO-8601 timestamp in UTC.
    ///
    /// Uses `ISO8601FormatStyle` with fractional seconds disabled so
    /// the output matches what `kubectl` prints
    /// (`2026-01-15T18:42:17Z`). `Date.now.ISO8601Format()` drops the
    /// fractional seconds by default and uses `Z`, so it is safe for
    /// round-tripping through the K8s API.
    static func currentTimestamp(now: Date = Date()) -> String {
        now.ISO8601Format()
    }

    /// Merges a new condition into an existing list.
    ///
    /// - If a condition with the same ``KubernetesCondition/type`` already
    ///   exists and its ``KubernetesCondition/status`` is unchanged, the
    ///   prior ``KubernetesCondition/lastTransitionTime`` is preserved but
    ///   reason / message / observedGeneration are refreshed.
    /// - If status changed (or the type is new), `lastTransitionTime` is
    ///   set to ``now``.
    /// - The returned list is sorted by type so diffs against the K8s
    ///   API are deterministic.
    static func merge(
        existing: [KubernetesCondition],
        with new: KubernetesCondition,
        now: Date = Date()
    ) -> [KubernetesCondition] {
        var result = existing
        let nowString = currentTimestamp(now: now)

        if let index = result.firstIndex(where: { $0.type == new.type }) {
            let prior = result[index]
            let transitionTime: String = prior.status == new.status
                ? prior.lastTransitionTime
                : nowString
            result[index] = KubernetesCondition(
                type: new.type,
                status: new.status,
                reason: new.reason,
                message: new.message,
                lastTransitionTime: transitionTime,
                observedGeneration: new.observedGeneration
            )
        } else {
            let created = KubernetesCondition(
                type: new.type,
                status: new.status,
                reason: new.reason,
                message: new.message,
                lastTransitionTime: nowString,
                observedGeneration: new.observedGeneration
            )
            result.append(created)
        }

        return result.sorted { $0.type < $1.type }
    }

    /// Convenience: merge many conditions at once, in input order.
    static func merge(
        existing: [KubernetesCondition],
        with updates: [KubernetesCondition],
        now: Date = Date()
    ) -> [KubernetesCondition] {
        updates.reduce(existing) { acc, next in
            merge(existing: acc, with: next, now: now)
        }
    }

    /// Builds the three standard MacOSVM conditions
    /// (`Available`, `Progressing`, `Degraded`) from a phase value. The
    /// controller calls this on every status write so the condition
    /// list always reflects the most recent phase transition.
    static func macOSVMConditions(
        phase: MacOSVMStatus.Phase,
        observedGeneration: Int64?,
        message: String?
    ) -> [KubernetesCondition] {
        let msg = message ?? phase.rawValue

        let available = KubernetesCondition(
            type: KubernetesCondition.StandardType.available,
            status: phase == .running
                ? KubernetesCondition.StandardStatus.true
                : KubernetesCondition.StandardStatus.false,
            reason: phase.rawValue,
            message: msg,
            lastTransitionTime: "",  // merged against prior conditions
            observedGeneration: observedGeneration
        )

        let progressingStatus: String
        switch phase {
        case .pending, .cloning, .starting, .stopping:
            progressingStatus = KubernetesCondition.StandardStatus.true
        case .running, .failed, .deleted:
            progressingStatus = KubernetesCondition.StandardStatus.false
        }
        let progressing = KubernetesCondition(
            type: KubernetesCondition.StandardType.progressing,
            status: progressingStatus,
            reason: phase.rawValue,
            message: msg,
            lastTransitionTime: "",
            observedGeneration: observedGeneration
        )

        let degraded = KubernetesCondition(
            type: KubernetesCondition.StandardType.degraded,
            status: phase == .failed
                ? KubernetesCondition.StandardStatus.true
                : KubernetesCondition.StandardStatus.false,
            reason: phase.rawValue,
            message: msg,
            lastTransitionTime: "",
            observedGeneration: observedGeneration
        )

        return [available, progressing, degraded]
    }

    // MARK: RunnerPool Conditions

    /// Computes the four standard RunnerPool conditions from pool vitals.
    ///
    /// Types:
    /// - `PoolReady` — active runners >= minRunners.
    /// - `ScaleUpInProgress` — a create is pending or below target.
    /// - `ScaleDownInProgress` — a delete is pending or above target.
    /// - `CapacityExhausted` — no candidate node has free slots.
    static func runnerPoolConditions(
        observedGeneration: Int64?,
        minRunners: Int,
        readyRunners: Int,
        activeRunners: Int,
        desiredRunners: Int,
        capacityExhausted: Bool,
        message: String?
    ) -> [KubernetesCondition] {
        let msg = message ?? ""

        let ready = readyRunners >= minRunners
        let poolReady = KubernetesCondition(
            type: "PoolReady",
            status: ready
                ? KubernetesCondition.StandardStatus.true
                : KubernetesCondition.StandardStatus.false,
            reason: ready ? "MinimumSatisfied" : "BelowMinimum",
            message: ready
                ? "\(readyRunners) ready runners (minimum \(minRunners))"
                : "\(readyRunners) / \(minRunners) ready runners",
            lastTransitionTime: "",
            observedGeneration: observedGeneration
        )

        let scalingUp = activeRunners < desiredRunners
        let scaleUp = KubernetesCondition(
            type: "ScaleUpInProgress",
            status: scalingUp
                ? KubernetesCondition.StandardStatus.true
                : KubernetesCondition.StandardStatus.false,
            reason: scalingUp ? "BelowDesired" : "AtDesired",
            message: "active=\(activeRunners) desired=\(desiredRunners)",
            lastTransitionTime: "",
            observedGeneration: observedGeneration
        )

        let scalingDown = activeRunners > desiredRunners
        let scaleDown = KubernetesCondition(
            type: "ScaleDownInProgress",
            status: scalingDown
                ? KubernetesCondition.StandardStatus.true
                : KubernetesCondition.StandardStatus.false,
            reason: scalingDown ? "AboveDesired" : "AtDesired",
            message: "active=\(activeRunners) desired=\(desiredRunners)",
            lastTransitionTime: "",
            observedGeneration: observedGeneration
        )

        let capacity = KubernetesCondition(
            type: "CapacityExhausted",
            status: capacityExhausted
                ? KubernetesCondition.StandardStatus.true
                : KubernetesCondition.StandardStatus.false,
            reason: capacityExhausted ? "NoFreeHostSlots" : "SlotsAvailable",
            message: msg.isEmpty
                ? (capacityExhausted
                    ? "All candidate nodes at 2-VM host limit"
                    : "Host capacity available")
                : msg,
            lastTransitionTime: "",
            observedGeneration: observedGeneration
        )

        return [poolReady, scaleUp, scaleDown, capacity]
    }
}

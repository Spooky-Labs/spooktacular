import Foundation
import os
import SpooktacularKit

/// Watches RunnerPool custom resources and delegates to ``RunnerPoolManager``.
///
/// This is a thin K8s adapter following Clean Swift: it reads CRD state,
/// calls SpooktacularKit, and writes status back. No business logic here.
actor RunnerPoolReconciler {

    private let client: KubernetesClient
    private let manager: RunnerPoolManager
    private let logger = Logger(subsystem: "com.spooktacular.controller", category: "runnerpool")

    init(client: KubernetesClient, manager: RunnerPoolManager) {
        self.client = client
        self.manager = manager
    }

    /// Main reconciliation loop. Watches RunnerPool CRDs and reconciles.
    func run() async {
        logger.notice("RunnerPoolReconciler starting")
        // Watch loop implementation follows the existing Reconciler.run() pattern:
        // list -> watch -> dispatch events -> call manager.reconcilePool() -> execute actions -> write status
        // Full implementation will be wired when the K8s watch for RunnerPool resources is added.
    }
}

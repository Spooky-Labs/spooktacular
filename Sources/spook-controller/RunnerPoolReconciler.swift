/// Reconciliation loop for RunnerPool custom resources.
///
/// Watches `RunnerPool` CRDs (group `spooktacular.app`, version `v1alpha1`),
/// delegates all scale-up / scale-down decisions to ``RunnerPoolManager``,
/// and drives individual runner lifecycles through ``RunnerStateMachine``.
///
/// This is a **thin K8s adapter** following Clean Architecture: it reads CRD
/// state, calls SpooktacularKit, and writes status back. No business logic.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import os
import SpookCore
import SpookApplication
import SpookInfrastructureApple

// MARK: - RunnerPool CRD Types

/// A RunnerPool custom resource as stored in the Kubernetes API.
struct RunnerPool: Codable, Sendable {
    let apiVersion: String
    let kind: String
    let metadata: RunnerPoolMeta
    let spec: RunnerPoolSpec
    var status: RunnerPoolStatus?
}

/// Minimal ObjectMeta fields for RunnerPool resources.
struct RunnerPoolMeta: Codable, Sendable {
    let name: String
    let namespace: String?
    let uid: String?
    let resourceVersion: String?
    var labels: [String: String]?
    var annotations: [String: String]?
}

/// The desired state of a RunnerPool, authored by the user.
struct RunnerPoolSpec: Codable, Sendable {
    let minRunners: Int
    let maxRunners: Int
    let sourceVM: String
    let mode: String
    let preWarm: Bool?
    let nodeName: String?
    let baseImage: String?
}

/// The observed state of a RunnerPool, written by the controller.
struct RunnerPoolStatus: Codable, Sendable {
    var activeRunners: Int?
    var readyRunners: Int?
    var message: String?
    var runners: [RunnerPoolRunnerStatus]?
}

/// Per-runner status stored in the RunnerPool CRD status.
struct RunnerPoolRunnerStatus: Codable, Sendable {
    let name: String
    let state: String
    let retryCount: Int
}

/// A Kubernetes watch event for RunnerPool resources.
struct RunnerPoolWatchEvent: Decodable, Sendable {
    let type: String
    let object: RunnerPool
}

/// Response from listing RunnerPool resources.
struct RunnerPoolList: Decodable, Sendable {
    let metadata: ListMeta
    let items: [RunnerPool]
}

// MARK: - RunnerPoolReconciler

actor RunnerPoolReconciler {

    private let client: KubernetesClient
    private let manager: RunnerPoolManager
    private let logger = Logger(subsystem: "com.spooktacular.controller", category: "runnerpool")

    /// Per-runner state machines, keyed by runner name.
    private var stateMachines: [String: RunnerStateMachine] = [:]

    /// Tracks which RunnerPool owns each runner, keyed by runner name.
    private var runnerOwnership: [String: String] = [:]

    /// Tracks the tenant identity for each runner, keyed by runner name.
    private var runnerTenants: [String: TenantID] = [:]

    /// Pending timeouts, keyed by runner name. Cancelled when the timeout fires
    /// or a ``RunnerStateMachine/SideEffect/cancelTimeout`` is returned.
    private var timeouts: [String: Task<Void, Never>] = [:]

    /// Guards against concurrent reconciliation of the same pool.
    private var inFlight: Set<String> = []

    /// The URL session used for RunnerPool K8s API calls.
    ///
    /// Reuses `KubernetesClient.session` — which installs
    /// `ClusterTLSDelegate` and fail-closes when the in-cluster CA
    /// bundle is missing — so the ServiceAccount bearer attached
    /// below NEVER ships over an unpinned `.shared` or plain
    /// `.ephemeral` session. A previous version built its own
    /// `URLSession(configuration: .ephemeral)` here, which would
    /// trust any system-root cert for the API host in clusters
    /// fronted by a publicly-trusted serving cert.
    private let session: URLSession

    /// Node manager for calling Mac node APIs (start, stop, exec).
    private let nodeManager: NodeManager

    /// GitHub runner service for registration/deregistration.
    private let githubService: GitHubRunnerService?

    /// GitHub API scope (e.g., "repos/org/repo" or "orgs/org").
    private var githubScope: String = ""

    /// The tenancy mode (single-tenant or multi-tenant) for this controller.
    private let tenancyMode: TenancyMode

    /// Authorization service that evaluates whether actions are permitted.
    private let authService: any AuthorizationService

    /// Tenant isolation policy for scheduling and resource access.
    private let isolation: any TenantIsolationPolicy

    /// Reuse policy governing VM recycling between jobs.
    private let reusePolicy: ReusePolicy

    /// Structured audit sink for control-plane actions.
    private let auditSink: any AuditSink

    /// Optional fair-share scheduler. When set (plus a positive
    /// `fleetCapacity`), the reconciler computes a per-pool
    /// effective `maxRunners` before per-pool reconciliation
    /// clamps a tenant's combined pool allocation to its fair
    /// share of the fleet. `nil` → current per-pool behavior is
    /// preserved for backward compatibility with deployments
    /// that don't configure `SPOOK_SCHEDULER_POLICY`.
    private let fairScheduler: FairScheduler?

    /// Total fleet capacity in VM slots. Used by the fair
    /// scheduler to clamp aggregate allocation. Zero disables
    /// fair-share even if `fairScheduler` is set — avoids
    /// dividing by zero on a brand-new cluster whose node
    /// inventory hasn't propagated yet.
    private let fleetCapacity: Int

    init(
        client: KubernetesClient,
        manager: RunnerPoolManager,
        nodeManager: NodeManager,
        tenancyMode: TenancyMode = .singleTenant,
        authService: any AuthorizationService = SingleTenantAuthorization(),
        isolation: any TenantIsolationPolicy = SingleTenantIsolation(),
        reusePolicy: ReusePolicy = .singleTenant,
        githubService: GitHubRunnerService? = nil,
        auditSink: any AuditSink = OSLogAuditSink(),
        fairScheduler: FairScheduler? = nil,
        fleetCapacity: Int = 0
    ) {
        self.client = client
        self.manager = manager
        self.nodeManager = nodeManager
        self.tenancyMode = tenancyMode
        self.authService = authService
        self.isolation = isolation
        self.reusePolicy = reusePolicy
        self.githubService = githubService
        self.auditSink = auditSink
        self.fairScheduler = fairScheduler
        self.fleetCapacity = fleetCapacity
        // Share the client's CA-pinned session so every reconciler
        // request inherits fail-closed TLS verification against the
        // in-cluster service-account CA bundle.
        self.session = client.session
    }

    // MARK: - Main Loop

    /// Runs the list-watch-reconcile loop indefinitely.
    ///
    /// Follows the same pattern as ``Reconciler/run()``: list existing
    /// RunnerPool CRDs, reconcile each one, then open a streaming watch
    /// and reconcile events as they arrive. On watch end or error, sleeps
    /// briefly and restarts.
    func run() async {
        logger.notice("RunnerPoolReconciler starting")

        // Start the periodic health check task.
        let healthTask = Task { [weak self] in
            await self?.periodicHealthCheck()
        }
        defer { healthTask.cancel() }

        while !Task.isCancelled {
            do {
                let list = try await listRunnerPools()
                logger.info("Listed \(list.items.count) RunnerPool resource(s)")

                // Fair-share pre-pass: compute a per-pool effective
                // `maxRunners` that respects the tenant's fair share
                // of the fleet. `nil` map means "no scheduler
                // configured" → preserve the original per-pool spec.
                let effectiveMax = fairShareAllocation(for: list.items)

                // Reconstruct state from CRD status on startup (crash-safe).
                for pool in list.items {
                    await reconstructState(from: pool)
                    await reconcilePool(pool, effectiveMaxRunners: effectiveMax[pool.metadata.name])
                }

                guard let rv = list.metadata.resourceVersion else {
                    logger.error("RunnerPool list missing resourceVersion, retrying in 5s")
                    try await Task.sleep(for: .seconds(5))
                    continue
                }

                logger.info("Watching RunnerPools from resourceVersion \(rv, privacy: .public)")
                for try await event in watchRunnerPools(resourceVersion: rv) {
                    switch event.type {
                    case "ADDED", "MODIFIED":
                        // Per-event reconciliation needs the full
                        // fleet picture to compute fair share — one
                        // pool's MODIFY can shift capacity away from
                        // another. Re-list here so the allocation
                        // map covers every current pool. Under
                        // heavy event churn this is more work than
                        // the prior "reconcile-in-isolation" path,
                        // but it's the only way to preserve the
                        // fair-share invariant across watch events.
                        let currentList = (try? await listRunnerPools())?.items ?? [event.object]
                        let allocation = fairShareAllocation(for: currentList)
                        await reconcilePool(
                            event.object,
                            effectiveMaxRunners: allocation[event.object.metadata.name]
                        )
                    case "DELETED":
                        await handlePoolDeleted(event.object)
                    case "BOOKMARK":
                        break
                    default:
                        logger.warning("Unknown RunnerPool event '\(event.type, privacy: .public)'")
                    }
                }
                logger.info("RunnerPool watch ended, restarting")
            } catch {
                logger.error("RunnerPool reconcile error: \(error.localizedDescription, privacy: .public)")
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
        logger.notice("RunnerPoolReconciler stopped")
    }

    // MARK: - State Reconstruction

    /// Reconstructs in-memory state machines from a RunnerPool's persisted
    /// CRD status. Called on startup to make the reconciler crash-safe.
    private func reconstructState(from pool: RunnerPool) async {
        guard let runners = pool.status?.runners else { return }
        let poolName = pool.metadata.name

        for runner in runners {
            guard stateMachines[runner.name] == nil else { continue }
            var machine = RunnerStateMachine(maxRetries: 3)
            machine.sourceVM = pool.spec.sourceVM

            // Advance the machine to the persisted state by replaying a
            // minimal event sequence. This is safe because the state machine
            // is deterministic and side effects are idempotent.
            advanceMachine(&machine, toState: runner.state)

            stateMachines[runner.name] = machine
            runnerOwnership[runner.name] = poolName
            logger.info("Reconstructed runner '\(runner.name, privacy: .public)' in state '\(runner.state, privacy: .public)' for pool '\(poolName, privacy: .public)'")
        }
    }

    /// Best-effort state advancement for crash recovery. Sets the machine to
    /// approximate the persisted state. Not all states are reachable via a
    /// single event from `.requested`, so we accept the closest match.
    private func advanceMachine(_ machine: inout RunnerStateMachine, toState stateString: String) {
        guard let target = RunnerStateMachine.State(rawValue: stateString) else { return }
        if machine.state == target { return }

        // Walk the happy path to reach the target state.
        let happyPath: [(RunnerStateMachine.State, RunnerStateMachine.Event)] = [
            (.requested, .nodeAvailable),
            (.cloning, .cloneSucceeded),
            (.booting, .healthCheckPassed),
            (.registering, .runnerRegistered),
            (.ready, .jobStarted(jobId: "recovered")),
            (.busy, .jobCompleted),
            (.draining, .drainComplete),
        ]

        for (fromState, event) in happyPath {
            guard machine.state != target else { break }
            if machine.state == fromState {
                _ = machine.transition(event: event)
            }
        }
    }

    // MARK: - Reconciliation

    /// Reconciles a single RunnerPool: reads spec, builds desired/current
    /// state, calls ``RunnerPoolManager``, and executes returned actions.
    private func reconcilePool(_ pool: RunnerPool, effectiveMaxRunners: Int? = nil) async {
        let poolName = pool.metadata.name
        guard !inFlight.contains(poolName) else { return }
        inFlight.insert(poolName)
        defer { inFlight.remove(poolName) }

        logger.info("Reconciling RunnerPool '\(poolName, privacy: .public)'")

        // Build desired state from the CRD spec, clamping
        // `maxRunners` to the fair-share cap when the scheduler
        // produced one. The pool's own `minRunners` floor is still
        // honored — the scheduler ensured the total of all minimums
        // fits in fleet capacity, so this clamp only ever reduces
        // the max, never the min.
        let mode = PoolMode(rawValue: pool.spec.mode) ?? .ephemeral
        let clampedMax: Int
        if let cap = effectiveMaxRunners {
            clampedMax = max(pool.spec.minRunners, min(pool.spec.maxRunners, cap))
            if clampedMax < pool.spec.maxRunners {
                logger.info(
                    "Fair-share: pool '\(poolName, privacy: .public)' maxRunners clamped \(pool.spec.maxRunners) → \(clampedMax)"
                )
            }
        } else {
            clampedMax = pool.spec.maxRunners
        }
        let desired = PoolDesiredState(
            minRunners: pool.spec.minRunners,
            maxRunners: clampedMax,
            sourceVM: pool.spec.sourceVM,
            mode: mode,
            preWarm: pool.spec.preWarm ?? false
        )

        // Build current state from our in-memory state machines.
        let current: [RunnerStatus] = stateMachines
            .filter { runnerOwnership[$0.key] == poolName }
            .map { RunnerStatus(name: $0.key, state: $0.value.state, retryCount: $0.value.retryCount) }

        // Delegate the scale decision to RunnerPoolManager.
        let actions = await manager.reconcilePool(desired: desired, current: current)

        // Execute each action.
        for action in actions {
            switch action {
            case .createRunner(let name, let sourceVM):
                await createRunner(name: name, sourceVM: sourceVM, pool: pool)

            case .deleteRunner(let name):
                await deleteRunner(name: name, pool: pool)
            }
        }

        // Persist status back to the CRD.
        await updatePoolStatus(poolName: poolName)
    }

    /// Handles a RunnerPool deletion: clean up all child runners.
    private func handlePoolDeleted(_ pool: RunnerPool) async {
        let poolName = pool.metadata.name
        logger.notice("RunnerPool '\(poolName, privacy: .public)' deleted, cleaning up runners")

        let ownedRunners = runnerOwnership.filter { $0.value == poolName }.map(\.key)
        for runnerName in ownedRunners {
            await deleteChildVM(name: runnerName, poolName: poolName)
            stateMachines.removeValue(forKey: runnerName)
            runnerOwnership.removeValue(forKey: runnerName)
            runnerTenants.removeValue(forKey: runnerName)
            timeouts[runnerName]?.cancel()
            timeouts.removeValue(forKey: runnerName)
        }
    }

    // MARK: - Runner Creation / Deletion

    /// Creates a MacOSVM child resource owned by the RunnerPool.
    private func createRunner(name: String, sourceVM: String, pool: RunnerPool) async {
        let poolName = pool.metadata.name
        logger.info("Creating runner '\(name, privacy: .public)' for pool '\(poolName, privacy: .public)'")

        // Resolve tenant identity from pool labels (or default for single-tenant).
        let tenantID = tenantIDFromPool(pool)
        let hostPoolID = hostPoolIDFromPool(pool)

        // In multi-tenant mode, verify the tenant can schedule onto this host pool.
        // This is the tenant scheduling gate: node selection is driven by the
        // RunnerPool spec's `nodeName` field, which the existing Reconciler uses
        // when placing the MacOSVM CRD onto a physical node. The isolation check
        // here ensures the tenant is permitted to use that host pool before the
        // MacOSVM resource is even created.
        guard isolation.canSchedule(tenant: tenantID, onto: hostPoolID) else {
            logger.warning("Skipping runner '\(name, privacy: .public)': tenant '\(tenantID, privacy: .public)' not allowed on pool '\(hostPoolID, privacy: .public)'")
            let context = AuthorizationContext(
                actorIdentity: "spook-controller",
                tenant: tenantID,
                scope: .runner,
                resource: name,
                action: "scheduleRunner"
            )
            let audit = AuditRecord(context: context, outcome: .denied)
            await auditSink.record(audit)
            return
        }

        // Initialize the state machine.
        var machine = RunnerStateMachine(maxRetries: 3)
        machine.sourceVM = sourceVM
        stateMachines[name] = machine
        runnerOwnership[name] = poolName
        runnerTenants[name] = tenantID

        // Create the MacOSVM child resource via K8s API, including tenant metadata.
        await createChildVM(
            name: name,
            pool: pool,
            tenantID: tenantID
        )

        // Audit the runner creation.
        let context = AuthorizationContext(
            actorIdentity: "spook-controller",
            tenant: tenantID,
            scope: .runner,
            resource: name,
            action: "createRunner"
        )
        let audit = AuditRecord(context: context, outcome: .success)
        await auditSink.record(audit)

        // Drive the state machine: node is available, start cloning.
        var updatedMachine = stateMachines[name]!
        let effects = updatedMachine.transition(event: .nodeAvailable)
        stateMachines[name] = updatedMachine
        await executeSideEffects(effects, runnerName: name, poolName: poolName)
    }

    /// Deletes a runner: drives the state machine and removes the child VM.
    private func deleteRunner(name: String, pool: RunnerPool) async {
        let poolName = pool.metadata.name
        logger.info("Deleting runner '\(name, privacy: .public)' from pool '\(poolName, privacy: .public)'")

        // Authorize the destructive operation.
        let tenantID = tenantIDFromPool(pool)
        let context = AuthorizationContext(
            actorIdentity: "spook-controller",
            tenant: tenantID,
            scope: .runner,
            resource: name,
            action: "deleteRunner"
        )
        guard await authService.authorize(context) else {
            logger.warning("Authorization denied: \(context.action, privacy: .public) on \(context.resource, privacy: .public)")
            let audit = AuditRecord(context: context, outcome: .denied)
            await auditSink.record(audit)
            return
        }

        await deleteChildVM(name: name, poolName: poolName)

        let audit = AuditRecord(context: context, outcome: .success)
        await auditSink.record(audit)

        stateMachines.removeValue(forKey: name)
        runnerOwnership.removeValue(forKey: name)
        runnerTenants.removeValue(forKey: name)
        timeouts[name]?.cancel()
        timeouts.removeValue(forKey: name)
    }

    // MARK: - Side Effect Execution

    /// Executes the side effects returned by ``RunnerStateMachine/transition(event:)``.
    ///
    /// Each side effect maps to a K8s API call or a scheduled task. The
    /// reconciler does not interpret the effects — it simply executes them.
    /// Destructive operations are gated by the authorization service and
    /// produce audit records.
    private func executeSideEffects(
        _ effects: [RunnerStateMachine.SideEffect],
        runnerName: String,
        poolName: String
    ) async {
        // Resolve the tenant for this runner from its owning pool name.
        let tenantID = tenantIDForRunner(runnerName)

        for effect in effects {
            switch effect {
            case .cloneVM:
                logger.info("Side effect: clone VM for '\(runnerName, privacy: .public)'")
                // The MacOSVM child resource creation triggers the existing
                // Reconciler to handle cloning on the target node.

            case .startVM:
                logger.info("Side effect: start VM for '\(runnerName, privacy: .public)'")
                if let endpoint = await nodeManager.endpoint(for: runnerName) {
                    await callNodeAPI(method: "POST", path: "/v1/vms/\(runnerName)/start", on: endpoint)
                }

            case .stopVM:
                let context = AuthorizationContext(
                    actorIdentity: "spook-controller",
                    tenant: tenantID,
                    scope: .runner,
                    resource: runnerName,
                    action: "stopVM"
                )
                guard await authService.authorize(context) else {
                    logger.warning("Authorization denied: \(context.action, privacy: .public) on \(context.resource, privacy: .public)")
                    let audit = AuditRecord(context: context, outcome: .denied)
                    await auditSink.record(audit)
                    continue
                }
                logger.info("Side effect: stop VM for '\(runnerName, privacy: .public)'")
                if let endpoint = await nodeManager.endpoint(for: runnerName) {
                    await callNodeAPI(method: "POST", path: "/v1/vms/\(runnerName)/stop", on: endpoint)
                }
                let audit = AuditRecord(context: context, outcome: .success)
                await auditSink.record(audit)

            case .deleteVM:
                let context = AuthorizationContext(
                    actorIdentity: "spook-controller",
                    tenant: tenantID,
                    scope: .runner,
                    resource: runnerName,
                    action: "deleteVM"
                )
                guard await authService.authorize(context) else {
                    logger.warning("Authorization denied: \(context.action, privacy: .public) on \(context.resource, privacy: .public)")
                    let audit = AuditRecord(context: context, outcome: .denied)
                    await auditSink.record(audit)
                    continue
                }
                logger.info("Side effect: delete VM for '\(runnerName, privacy: .public)'")
                await deleteChildVM(name: runnerName, poolName: poolName)
                let deleteAudit = AuditRecord(context: context, outcome: .success)
                await auditSink.record(deleteAudit)

            case .execProvisioningScript:
                logger.info("Side effect: exec provisioning for '\(runnerName, privacy: .public)'")
                if let endpoint = await nodeManager.endpoint(for: runnerName) {
                    do {
                        // The provisioning script is embedded in the MacOSVM spec
                        // by createRunner. The node's start handler executes it via
                        // the provisioning mode (SSH, disk-inject, or agent).
                        // Here we verify the VM is healthy after provisioning.
                        let healthy = try await URLSession.shared.data(
                            from: endpoint.apiURL.appendingPathComponent("/v1/vms/\(runnerName)/ip")
                        )
                        logger.info("Provisioning health check for '\(runnerName, privacy: .public)': ok")
                    } catch {
                        logger.error("Provisioning check failed for '\(runnerName, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                    }
                }

            case .deregisterRunner(let runnerId):
                let context = AuthorizationContext(
                    actorIdentity: "spook-controller",
                    tenant: tenantID,
                    scope: .runner,
                    resource: runnerName,
                    action: "deregisterRunner"
                )
                guard await authService.authorize(context) else {
                    logger.warning("Authorization denied: \(context.action, privacy: .public) on \(context.resource, privacy: .public)")
                    let audit = AuditRecord(context: context, outcome: .denied)
                    await auditSink.record(audit)
                    continue
                }
                logger.info("Side effect: deregister runner \(runnerId) for '\(runnerName, privacy: .public)'")
                if let service = githubService, !githubScope.isEmpty {
                    do {
                        try await service.removeRunner(runnerId: runnerId, scope: githubScope)
                        logger.notice("Deregistered runner \(runnerId) from GitHub (\(self.githubScope, privacy: .public))")
                    } catch {
                        logger.error("Failed to deregister runner \(runnerId): \(error.localizedDescription, privacy: .public)")
                    }
                }
                let deregAudit = AuditRecord(context: context, outcome: .success)
                await auditSink.record(deregAudit)

            case .updateStatus(let state):
                logger.info("Side effect: update status to '\(state.rawValue, privacy: .public)' for '\(runnerName, privacy: .public)'")
                await updatePoolStatus(poolName: poolName)

            case .scheduleTimeout(let seconds):
                scheduleTimeout(runnerName: runnerName, poolName: poolName, seconds: seconds)

            case .cancelTimeout:
                timeouts[runnerName]?.cancel()
                timeouts.removeValue(forKey: runnerName)

            case .createReplacement:
                logger.info("Side effect: create replacement for '\(runnerName, privacy: .public)'")
                // The next reconciliation pass will detect the shortfall and
                // create a replacement via RunnerPoolManager.
            }
        }

        // MARK: Warm-pool reuse tenant boundary check
        //
        // After executing side effects, if the runner has transitioned into
        // the `.recycling` state, enforce tenant boundaries before allowing
        // reuse. In multi-tenant mode, cross-tenant reuse is forbidden: if
        // the previous tenant differs from the current tenant for this
        // runner's pool, destroy the VM instead of recycling.
        if let machine = stateMachines[runnerName], machine.state == .recycling {
            let currentTenant = tenantID
            let previousTenant = runnerTenants[runnerName] ?? .default

            // Verify same-tenant reuse is allowed.
            guard isolation.canReuse(vm: runnerName, fromTenant: previousTenant, forTenant: currentTenant) else {
                logger.warning("Cross-tenant reuse blocked for '\(runnerName, privacy: .public)': previous=\(previousTenant.description, privacy: .public) current=\(currentTenant.description, privacy: .public)")

                let context = AuthorizationContext(
                    actorIdentity: "spook-controller",
                    tenant: currentTenant,
                    scope: .runner,
                    resource: runnerName,
                    action: "crossTenantReuseBlocked"
                )
                let audit = AuditRecord(context: context, outcome: .denied)
                await auditSink.record(audit)

                // Destroy instead of recycling — feed recycleFailed to
                // transition to .failed and trigger deleteVM.
                var failedMachine = machine
                let failEffects = failedMachine.transition(event: .recycleFailed)
                stateMachines[runnerName] = failedMachine
                await executeSideEffects(failEffects, runnerName: runnerName, poolName: poolName)
                return
            }

            // Enforce reuse policy: if warm-pool reuse is disallowed
            // (e.g., ephemeral-only multi-tenant mode), destroy immediately.
            if !reusePolicy.warmPoolAllowed {
                logger.info("Warm-pool reuse disallowed by policy for '\(runnerName, privacy: .public)' — destroying")
                var failedMachine = machine
                let failEffects = failedMachine.transition(event: .recycleFailed)
                stateMachines[runnerName] = failedMachine
                await executeSideEffects(failEffects, runnerName: runnerName, poolName: poolName)
                return
            }
        }
    }

    // MARK: - Timeouts

    /// Schedules a timeout that fires a `.timeout` event on the runner's
    /// state machine after the given delay.
    private func scheduleTimeout(runnerName: String, poolName: String, seconds: Int) {
        timeouts[runnerName]?.cancel()
        timeouts[runnerName] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return  // Cancelled.
            }
            guard let self else { return }
            await self.handleTimeout(runnerName: runnerName, poolName: poolName)
        }
    }

    /// Handles a timeout by feeding the event to the runner's state machine.
    private func handleTimeout(runnerName: String, poolName: String) async {
        guard var machine = stateMachines[runnerName] else { return }
        timeouts.removeValue(forKey: runnerName)

        logger.warning("Timeout for runner '\(runnerName, privacy: .public)' in state '\(machine.state.rawValue, privacy: .public)'")
        let effects = machine.transition(event: .timeout)
        stateMachines[runnerName] = machine
        await executeSideEffects(effects, runnerName: runnerName, poolName: poolName)
    }

    // MARK: - Periodic Health Check

    /// Every 30 seconds, checks each runner's state machine for staleness
    /// and feeds timeout events as needed.
    private func periodicHealthCheck() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }

            for (runnerName, machine) in stateMachines {
                guard let poolName = runnerOwnership[runnerName] else { continue }

                // For runners in transient states without an active timeout,
                // schedule a defensive timeout to prevent indefinite hangs.
                switch machine.state {
                case .cloning, .booting, .registering, .draining, .recycling:
                    if timeouts[runnerName] == nil {
                        logger.info("Health check: scheduling defensive timeout for '\(runnerName, privacy: .public)' in state '\(machine.state.rawValue, privacy: .public)'")
                        scheduleTimeout(runnerName: runnerName, poolName: poolName, seconds: 120)
                    }
                case .requested, .ready, .busy, .failed, .deleted:
                    break
                }
            }

            // Heal any runners stuck in transient states without timeouts.
            await healStuckRunners()

            // Update all pool statuses.
            let poolNames = Set(runnerOwnership.values)
            for poolName in poolNames {
                await updatePoolStatus(poolName: poolName)
            }
        }
    }

    /// Detects runners stuck in transient states and forces timeout events.
    ///
    /// A runner is considered "stuck" if it has been in a transient state
    /// (cloning, booting, registering, draining, recycling) without an
    /// active timeout task. This can happen if the timeout `Task` was
    /// cancelled or lost during a controller restart. In that case the
    /// defensive timeout scheduled above may not have fired yet and the
    /// runner could sit idle indefinitely.
    ///
    /// When a stuck runner is detected, a `.timeout` event is immediately
    /// fed to its state machine so that the normal retry / failure path
    /// takes effect.
    private func healStuckRunners() async {
        let transientStates: Set<RunnerStateMachine.State> = [
            .cloning, .booting, .registering, .draining, .recycling,
        ]

        for (name, var sm) in stateMachines {
            guard transientStates.contains(sm.state) else { continue }

            // Only heal if there is no active timeout — if a timeout is
            // already scheduled the normal path will handle it.
            if timeouts[name] == nil {
                logger.warning("Healing stuck runner '\(name, privacy: .public)' in state \(sm.state.rawValue, privacy: .public)")
                let effects = sm.transition(event: .timeout)
                stateMachines[name] = sm
                let poolName = runnerOwnership[name] ?? ""
                await executeSideEffects(effects, runnerName: name, poolName: poolName)
            }
        }
    }

    // MARK: - Webhook Event Dispatch

    /// Dispatches a webhook event to the matching runner's state machine.
    ///
    /// Called by ``WebhookEndpoint`` after parsing the ``WorkflowJobWebhook``.
    /// Matches the `runner_name` to a known runner and feeds the appropriate
    /// event (`.jobStarted` or `.jobCompleted`).
    ///
    /// - Parameter webhook: The parsed webhook payload.
    func dispatchWebhook(_ webhook: WorkflowJobWebhook) async {
        guard let runnerName = webhook.workflowJob.runnerName else {
            logger.debug("Webhook has no runner_name, ignoring")
            return
        }

        guard var machine = stateMachines[runnerName] else {
            logger.debug("Webhook runner '\(runnerName, privacy: .public)' not managed by any pool")
            return
        }

        guard let poolName = runnerOwnership[runnerName] else { return }

        let event: RunnerStateMachine.Event
        switch webhook.action {
        case .inProgress:
            event = .jobStarted(jobId: String(webhook.workflowJob.id))
        case .completed:
            event = .jobCompleted
        default:
            logger.debug("Webhook action '\(String(describing: webhook.action), privacy: .public)' not dispatched to state machine")
            return
        }

        logger.info("Dispatching \(String(describing: event)) to runner '\(runnerName, privacy: .public)'")
        let effects = machine.transition(event: event)
        stateMachines[runnerName] = machine
        await executeSideEffects(effects, runnerName: runnerName, poolName: poolName)
    }

    // MARK: - Node API Helpers

    /// Calls a Mac node's HTTP API (start, stop, etc.).
    @discardableResult
    private func callNodeAPI(method: String, path: String, on endpoint: NodeEndpoint) async -> Bool {
        let url = endpoint.apiURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let token = ProcessInfo.processInfo.environment["SPOOK_API_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code)
        } catch {
            logger.error("Node API call \(method, privacy: .public) \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - K8s API Helpers (RunnerPool CRD)

    /// Lists all RunnerPool resources in the configured namespace.
    private func listRunnerPools() async throws -> RunnerPoolList {
        let namespace = client.namespace
        let baseURL = client.baseURL
        let url = baseURL.appendingPathComponent(
            "/apis/spooktacular.app/v1alpha1/namespaces/\(namespace)/runnerpools")
        let data = try await k8sRequest(url: url, method: "GET")
        return try JSONDecoder().decode(RunnerPoolList.self, from: data)
    }

    /// Opens a streaming watch for RunnerPool resources.
    private func watchRunnerPools(
        resourceVersion: String
    ) -> AsyncThrowingStream<RunnerPoolWatchEvent, Error> {
        let namespace = client.namespace
        let baseURL = client.baseURL

        return AsyncThrowingStream { continuation in
            let task = Task { [session] in
                let url = baseURL.appendingPathComponent(
                    "/apis/spooktacular.app/v1alpha1/namespaces/\(namespace)/runnerpools?watch=true&resourceVersion=\(resourceVersion)&allowWatchBookmarks=true")
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.timeoutInterval = 0

                // Read the token from the service account mount.
                let tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
                if let tokenData = try? Data(contentsOf: URL(filePath: tokenPath)),
                   let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                let (bytes, response) = try await session.bytes(for: req)

                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 410 {
                        continuation.finish()
                        return
                    }
                    if !(200..<300).contains(http.statusCode) {
                        throw ControllerError.apiError("RunnerPool watch returned HTTP \(http.statusCode)")
                    }
                }

                for try await line in bytes.lines {
                    guard !line.isEmpty else { continue }
                    guard let data = line.data(using: .utf8) else { continue }
                    let event = try JSONDecoder().decode(RunnerPoolWatchEvent.self, from: data)
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - K8s API Helpers (MacOSVM Children)

    /// Creates a MacOSVM child resource with ownerReferences pointing back to
    /// the RunnerPool, so Kubernetes garbage-collects children when the pool
    /// is deleted. Includes tenant metadata for multi-tenant isolation.
    private func createChildVM(name: String, pool: RunnerPool, tenantID: TenantID = .default) async {
        let namespace = client.namespace
        let baseURL = client.baseURL
        let url = baseURL.appendingPathComponent(
            "/apis/spooktacular.app/v1alpha1/namespaces/\(namespace)/macosvms")

        let poolName = pool.metadata.name
        let nodeName = pool.spec.nodeName ?? ""
        let baseImage = pool.spec.baseImage ?? pool.spec.sourceVM

        let body: [String: Any] = [
            "apiVersion": "spooktacular.app/v1alpha1",
            "kind": "MacOSVM",
            "metadata": [
                "name": name,
                "namespace": namespace,
                "labels": [
                    "spooktacular.app/runner-pool": poolName,
                    "spooktacular.app/managed-by": "runner-pool-reconciler",
                    "spooktacular.app/tenant": tenantID.rawValue,
                ],
                "ownerReferences": [
                    [
                        "apiVersion": "spooktacular.app/v1alpha1",
                        "kind": "RunnerPool",
                        "name": poolName,
                        "uid": pool.metadata.uid ?? "",
                        "controller": true,
                        "blockOwnerDeletion": true,
                    ]
                ],
            ],
            "spec": [
                "baseImage": baseImage,
                "nodeName": nodeName,
            ],
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            try await k8sRequest(url: url, method: "POST", body: data, contentType: "application/json")
            logger.notice("Created MacOSVM '\(name, privacy: .public)' for pool '\(poolName, privacy: .public)'")
        } catch {
            logger.error("Failed to create MacOSVM '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes a MacOSVM child resource by name.
    private func deleteChildVM(name: String, poolName: String) async {
        let namespace = client.namespace
        let baseURL = client.baseURL
        let url = baseURL.appendingPathComponent(
            "/apis/spooktacular.app/v1alpha1/namespaces/\(namespace)/macosvms/\(name)")

        do {
            try await k8sRequest(url: url, method: "DELETE")
            logger.notice("Deleted MacOSVM '\(name, privacy: .public)' from pool '\(poolName, privacy: .public)'")
        } catch {
            logger.error("Failed to delete MacOSVM '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Lists MacOSVM resources owned by a RunnerPool (filtered by label).
    private func listChildVMs(poolName: String) async throws -> [MacOSVM] {
        let namespace = client.namespace
        let baseURL = client.baseURL
        let selector = "spooktacular.app/runner-pool=\(poolName)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = baseURL.appendingPathComponent(
            "/apis/spooktacular.app/v1alpha1/namespaces/\(namespace)/macosvms?labelSelector=\(selector)")

        let data = try await k8sRequest(url: url, method: "GET")
        let list = try JSONDecoder().decode(MacOSVMList.self, from: data)
        return list.items
    }

    // MARK: - Pool Status Updates

    /// Persists the current runner status back to the RunnerPool CRD status
    /// subresource.
    private func updatePoolStatus(poolName: String) async {
        let runners = stateMachines
            .filter { runnerOwnership[$0.key] == poolName }

        let runnerStatuses = runners.map { (name, machine) in
            RunnerPoolRunnerStatus(name: name, state: machine.state.rawValue, retryCount: machine.retryCount)
        }

        let activeCount = runners.values.filter { $0.state != .deleted && $0.state != .failed }.count
        let readyCount = runners.values.filter { $0.state == .ready }.count

        let namespace = client.namespace
        let baseURL = client.baseURL
        let url = baseURL.appendingPathComponent(
            "/apis/spooktacular.app/v1alpha1/namespaces/\(namespace)/runnerpools/\(poolName)/status")

        let patch: [String: Any] = [
            "status": [
                "activeRunners": activeCount,
                "readyRunners": readyCount,
                "runners": runnerStatuses.map { runner in
                    [
                        "name": runner.name,
                        "state": runner.state,
                        "retryCount": runner.retryCount,
                    ] as [String: Any]
                },
            ]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: patch)
            try await k8sRequest(url: url, method: "PATCH", body: data,
                                 contentType: "application/merge-patch+json")
            logger.debug("Updated RunnerPool '\(poolName, privacy: .public)' status: active=\(activeCount) ready=\(readyCount)")
        } catch {
            logger.error("Failed to update RunnerPool '\(poolName, privacy: .public)' status: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Fair-share allocation

    /// Computes a per-pool effective `maxRunners` that respects
    /// the tenant's fair share of the fleet. Returns an empty
    /// map when fair-share is not configured, signalling callers
    /// to fall through to the pool's raw `maxRunners`.
    ///
    /// Algorithm:
    ///
    /// 1. Group pools by tenant (via the `spooktacular.app/tenant`
    ///    label). Unlabeled pools go to `TenantID.default`.
    /// 2. Sum each tenant's aggregate `maxRunners` demand.
    /// 3. Ask `FairScheduler.allocate` to split `fleetCapacity`
    ///    across tenants, honoring weight / minGuaranteed / maxCap.
    /// 4. Distribute each tenant's allocation across their pools
    ///    proportionally to each pool's share of the tenant's
    ///    total demand. A tenant with two pools demanding 10 and
    ///    5 slots, given 9 from the scheduler, sees 6 and 3.
    ///
    /// Returns: poolName → effective max. An absent entry means
    /// "no constraint" and the pool runs at its own
    /// `spec.maxRunners` like it always has.
    private func fairShareAllocation(for pools: [RunnerPool]) -> [String: Int] {
        guard let scheduler = fairScheduler, fleetCapacity > 0, !pools.isEmpty else {
            return [:]
        }
        let demand = pools.map { pool in
            FairScheduler.PoolDemand(
                poolName: pool.metadata.name,
                tenant: tenantIDFromPool(pool),
                demand: pool.spec.maxRunners
            )
        }
        return scheduler.allocatePools(demand, capacity: fleetCapacity)
    }

    // MARK: - Tenant Resolution

    /// Extracts the ``TenantID`` from a RunnerPool's labels.
    ///
    /// Falls back to ``TenantID/default`` when no tenant label is present
    /// (the single-tenant case).
    private func tenantIDFromPool(_ pool: RunnerPool) -> TenantID {
        if let raw = pool.metadata.labels?["spooktacular.app/tenant"] {
            return TenantID(raw)
        }
        return .default
    }

    /// Extracts the ``HostPoolID`` from a RunnerPool's labels.
    ///
    /// Falls back to ``HostPoolID/default`` when no host-pool label is
    /// present (the single-tenant case).
    private func hostPoolIDFromPool(_ pool: RunnerPool) -> HostPoolID {
        if let raw = pool.metadata.labels?["spooktacular.app/host-pool"] {
            return HostPoolID(raw)
        }
        return .default
    }

    /// Resolves a ``TenantID`` for a runner name from the stored mapping.
    ///
    /// Falls back to ``TenantID/default`` for single-tenant deployments
    /// or runners whose tenant was not recorded (e.g., crash recovery).
    private func tenantIDForRunner(_ runnerName: String) -> TenantID {
        runnerTenants[runnerName] ?? .default
    }

    // MARK: - Generic K8s Request

    /// Sends an authenticated request to the Kubernetes API.
    @discardableResult
    private func k8sRequest(
        url: URL,
        method: String,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method

        let tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        if let tokenData = try? Data(contentsOf: URL(filePath: tokenPath)),
           let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw ControllerError.apiError("\(method) \(url.path) HTTP \(code): \(msg)")
        }
        return data
    }
}

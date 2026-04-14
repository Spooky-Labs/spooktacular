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
import SpooktacularKit

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

    /// Pending timeouts, keyed by runner name. Cancelled when the timeout fires
    /// or a ``RunnerStateMachine/SideEffect/cancelTimeout`` is returned.
    private var timeouts: [String: Task<Void, Never>] = [:]

    /// Guards against concurrent reconciliation of the same pool.
    private var inFlight: Set<String> = []

    /// The URL session used for RunnerPool K8s API calls.
    private let session: URLSession

    init(client: KubernetesClient, manager: RunnerPoolManager) {
        self.client = client
        self.manager = manager
        self.session = URLSession(configuration: .ephemeral)
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

                // Reconstruct state from CRD status on startup (crash-safe).
                for pool in list.items {
                    await reconstructState(from: pool)
                    await reconcilePool(pool)
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
                        await reconcilePool(event.object)
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
    private func reconcilePool(_ pool: RunnerPool) async {
        let poolName = pool.metadata.name
        guard !inFlight.contains(poolName) else { return }
        inFlight.insert(poolName)
        defer { inFlight.remove(poolName) }

        logger.info("Reconciling RunnerPool '\(poolName, privacy: .public)'")

        // Build desired state from the CRD spec.
        let mode = PoolMode(rawValue: pool.spec.mode) ?? .ephemeral
        let desired = PoolDesiredState(
            minRunners: pool.spec.minRunners,
            maxRunners: pool.spec.maxRunners,
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
            timeouts[runnerName]?.cancel()
            timeouts.removeValue(forKey: runnerName)
        }
    }

    // MARK: - Runner Creation / Deletion

    /// Creates a MacOSVM child resource owned by the RunnerPool.
    private func createRunner(name: String, sourceVM: String, pool: RunnerPool) async {
        let poolName = pool.metadata.name
        logger.info("Creating runner '\(name, privacy: .public)' for pool '\(poolName, privacy: .public)'")

        // Initialize the state machine.
        var machine = RunnerStateMachine(maxRetries: 3)
        machine.sourceVM = sourceVM
        stateMachines[name] = machine
        runnerOwnership[name] = poolName

        // Create the MacOSVM child resource via K8s API.
        await createChildVM(
            name: name,
            pool: pool
        )

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

        await deleteChildVM(name: name, poolName: poolName)

        stateMachines.removeValue(forKey: name)
        runnerOwnership.removeValue(forKey: name)
        timeouts[name]?.cancel()
        timeouts.removeValue(forKey: name)
    }

    // MARK: - Side Effect Execution

    /// Executes the side effects returned by ``RunnerStateMachine/transition(event:)``.
    ///
    /// Each side effect maps to a K8s API call or a scheduled task. The
    /// reconciler does not interpret the effects — it simply executes them.
    private func executeSideEffects(
        _ effects: [RunnerStateMachine.SideEffect],
        runnerName: String,
        poolName: String
    ) async {
        for effect in effects {
            switch effect {
            case .cloneVM:
                logger.info("Side effect: clone VM for '\(runnerName, privacy: .public)'")
                // The MacOSVM child resource creation triggers the existing
                // Reconciler to handle cloning on the target node.

            case .startVM:
                logger.info("Side effect: start VM for '\(runnerName, privacy: .public)'")

            case .stopVM:
                logger.info("Side effect: stop VM for '\(runnerName, privacy: .public)'")

            case .deleteVM:
                logger.info("Side effect: delete VM for '\(runnerName, privacy: .public)'")
                await deleteChildVM(name: runnerName, poolName: poolName)

            case .execProvisioningScript:
                logger.info("Side effect: exec provisioning for '\(runnerName, privacy: .public)'")

            case .deregisterRunner(let runnerId):
                logger.info("Side effect: deregister runner \(runnerId) for '\(runnerName, privacy: .public)'")

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

            // Update all pool statuses.
            let poolNames = Set(runnerOwnership.values)
            for poolName in poolNames {
                await updatePoolStatus(poolName: poolName)
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
                if let tokenData = FileManager.default.contents(atPath: tokenPath),
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
    /// is deleted.
    private func createChildVM(name: String, pool: RunnerPool) async {
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
        if let tokenData = FileManager.default.contents(atPath: tokenPath),
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

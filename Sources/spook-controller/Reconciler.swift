/// The reconciliation loop for MacOSVM custom resources.
///
/// Implements the standard Kubernetes controller pattern: list existing
/// resources, watch for changes, and reconcile each event by calling the
/// Spooktacular HTTP API on the target Mac node.
///
/// The reconciler is stateless. All authoritative state lives in the
/// Kubernetes API (CRD status) and on Mac nodes (VM bundles).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import os

// MARK: - Reconciler

actor Reconciler {

    private let client: KubernetesClient
    private let nodeManager: NodeManager
    private let session = URLSession(configuration: .ephemeral)
    private let logger = Logger(subsystem: "com.spooktacular.controller", category: "reconciler")
    private var inFlight: Set<String> = []

    init(client: KubernetesClient, nodeManager: NodeManager) {
        self.client = client
        self.nodeManager = nodeManager
    }

    // MARK: - Main Loop

    /// Runs the list-watch-reconcile loop indefinitely.
    func run() async {
        logger.notice("Reconciler starting")

        while !Task.isCancelled {
            do {
                await nodeManager.refreshNodes(using: client)

                let list = try await client.listVMs()
                logger.info("Listed \(list.items.count) MacOSVM resource(s)")
                for vm in list.items { await reconcile(vm: vm, eventType: "ADDED") }

                guard let rv = list.metadata.resourceVersion else {
                    logger.error("List missing resourceVersion, retrying in 5s")
                    try await Task.sleep(for: .seconds(5))
                    continue
                }

                logger.info("Watching from resourceVersion \(rv, privacy: .public)")
                for try await event in await client.watchVMs(resourceVersion: rv) {
                    await nodeManager.checkHealth()
                    await reconcile(vm: event.object, eventType: event.type)
                }
                logger.info("Watch ended, restarting")
            } catch {
                logger.error("Reconcile error: \(error.localizedDescription, privacy: .public)")
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
        logger.notice("Reconciler stopped")
    }

    // MARK: - Reconcile

    private func reconcile(vm: MacOSVM, eventType: String) async {
        let name = vm.metadata.name
        let uid = vm.metadata.uid ?? name
        guard !inFlight.contains(uid) else { return }
        inFlight.insert(uid)
        defer { inFlight.remove(uid) }

        logger.info("Reconciling '\(name, privacy: .public)' event=\(eventType, privacy: .public)")
        switch eventType {
        case "ADDED":    await handleAdded(vm)
        case "MODIFIED": await handleModified(vm)
        case "DELETED":  await handleDeleted(vm)
        case "BOOKMARK": break
        default: logger.warning("Unknown event '\(eventType, privacy: .public)' for '\(name, privacy: .public)'")
        }
    }

    private static let finalizerName = "spooktacular.app/cleanup"

    // MARK: - Event Handlers

    /// ADDED: clone the base image then start the VM, and attach a finalizer.
    private func handleAdded(_ vm: MacOSVM) async {
        let name = vm.metadata.name
        let nodeName = vm.spec.nodeName

        if vm.status?.phase == .running { return }

        guard let endpoint = await nodeManager.endpoint(for: nodeName) else {
            await setStatus(name: name, phase: .failed, message: "Node '\(nodeName)' not found")
            return
        }

        // Clone
        await setStatus(name: name, phase: .cloning, nodeName: nodeName)
        let cloneResult = await callNodeAPI(endpoint: endpoint, method: "POST",
                                            path: "/v1/vms/\(name)/clone", body: ["source": vm.spec.baseImage])
        switch cloneResult {
        case .success: logger.info("Cloned '\(name, privacy: .public)' on \(nodeName, privacy: .public)")
        case .conflict: logger.info("VM '\(name, privacy: .public)' exists on \(nodeName, privacy: .public)")
        case .failure(let msg):
            await setStatus(name: name, phase: .failed, nodeName: nodeName, message: "Clone failed: \(msg)")
            return
        }

        // Start
        await setStatus(name: name, phase: .starting, nodeName: nodeName)
        let startResult = await callNodeAPI(endpoint: endpoint, method: "POST",
                                            path: "/v1/vms/\(name)/start", body: nil)
        switch startResult {
        case .success, .conflict:
            await setStatus(name: name, phase: .running, nodeName: nodeName)
            logger.notice("VM '\(name, privacy: .public)' running on \(nodeName, privacy: .public)")
            await resolveIP(name: name, endpoint: endpoint, nodeName: nodeName)
            await addFinalizer(name: name, existing: vm.metadata.finalizers)
        case .failure(let msg):
            await setStatus(name: name, phase: .failed, nodeName: nodeName, message: "Start failed: \(msg)")
        }
    }

    /// MODIFIED: retry failed VMs or resolve missing IPs.
    private func handleModified(_ vm: MacOSVM) async {
        let name = vm.metadata.name
        if vm.metadata.deletionTimestamp != nil { await handleDeleted(vm); return }
        if vm.status?.phase == .pending || vm.status?.phase == .failed { await handleAdded(vm); return }
        if vm.status?.phase == .running, vm.status?.ip == nil,
           let endpoint = await nodeManager.endpoint(for: vm.spec.nodeName) {
            await resolveIP(name: name, endpoint: endpoint, nodeName: vm.spec.nodeName)
        }
    }

    /// DELETED: stop then remove the VM from the node, then remove the finalizer.
    private func handleDeleted(_ vm: MacOSVM) async {
        let name = vm.metadata.name
        let nodeName = vm.spec.nodeName

        guard let endpoint = await nodeManager.endpoint(for: nodeName) else {
            logger.warning("Cannot delete '\(name, privacy: .public)': node '\(nodeName, privacy: .public)' not found")
            await removeFinalizer(name: name, existing: vm.metadata.finalizers)
            return
        }

        if case .success = await callNodeAPI(endpoint: endpoint, method: "POST",
                                             path: "/v1/vms/\(name)/stop", body: nil) {
            logger.info("Stopped '\(name, privacy: .public)' on \(nodeName, privacy: .public)")
            try? await Task.sleep(for: .seconds(2))
        }

        let result = await callNodeAPI(endpoint: endpoint, method: "DELETE",
                                       path: "/v1/vms/\(name)", body: nil)
        switch result {
        case .success: logger.notice("Deleted '\(name, privacy: .public)' from \(nodeName, privacy: .public)")
        case .conflict: logger.warning("VM '\(name, privacy: .public)' still running, may need retry")
        case .failure(let msg): logger.error("Delete failed for '\(name, privacy: .public)': \(msg, privacy: .public)")
        }

        await removeFinalizer(name: name, existing: vm.metadata.finalizers)
    }

    // MARK: - Finalizers

    /// Patches the cleanup finalizer onto the resource if not already present.
    private func addFinalizer(name: String, existing: [String]?) async {
        let current = existing ?? []
        guard !current.contains(Self.finalizerName) else { return }
        let updated = current + [Self.finalizerName]
        await patchFinalizers(name: name, finalizers: updated)
    }

    /// Removes the cleanup finalizer so Kubernetes can complete deletion.
    private func removeFinalizer(name: String, existing: [String]?) async {
        guard let current = existing, current.contains(Self.finalizerName) else { return }
        let updated = current.filter { $0 != Self.finalizerName }
        await patchFinalizers(name: name, finalizers: updated)
    }

    private func patchFinalizers(name: String, finalizers: [String]) async {
        do {
            let patch: [String: Any] = ["metadata": ["finalizers": finalizers]]
            let data = try JSONSerialization.data(withJSONObject: patch)
            try await client.mergePatch(name: name, body: data)
            logger.debug("Patched finalizers on '\(name, privacy: .public)': \(finalizers, privacy: .public)")
        } catch {
            logger.error("Failed to patch finalizers on '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - IP Resolution

    private func resolveIP(name: String, endpoint: NodeEndpoint, nodeName: String) async {
        if case .success(let data) = await callNodeAPI(endpoint: endpoint, method: "GET",
                                                       path: "/v1/vms/\(name)/ip", body: nil),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = json["data"] as? [String: Any],
           let ip = inner["ip"] as? String {
            await setStatus(name: name, phase: .running, ip: ip, nodeName: nodeName)
            logger.info("IP for '\(name, privacy: .public)': \(ip, privacy: .public)")
        }
    }

    // MARK: - Status Updates

    private func setStatus(name: String, phase: MacOSVMStatus.Phase,
                           ip: String? = nil, nodeName: String? = nil, message: String? = nil) async {
        do {
            try await client.updateStatus(name: name,
                                          status: MacOSVMStatus(phase: phase, ip: ip, nodeName: nodeName, message: message))
        } catch {
            logger.error("Status update failed for '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Node API Calls

    private enum NodeAPIResult { case success(Data), conflict, failure(String) }

    private func callNodeAPI(endpoint: NodeEndpoint, method: String,
                             path: String, body: [String: String]?) async -> NodeAPIResult {
        let url = endpoint.apiURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let token = ProcessInfo.processInfo.environment["SPOOK_API_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: return .success(data)
            case 409:       return .conflict
            default:        return .failure(extractError(from: data) ?? "HTTP \(code)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func extractError(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
    }
}

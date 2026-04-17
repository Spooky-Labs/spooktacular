import Foundation
import AppIntents
import SpooktacularKit

/// Thin bridge so `AppIntent.perform` can drive the same lifecycle
/// operations the GUI calls into.
///
/// Intents run either in-process when the app is foregrounded or
/// out-of-process via the intents extension when it isn't. In the
/// latter case we refresh VM state from disk on each call — no
/// shared mutable `AppState` required.
///
/// The shared singleton is **only** used inside intent `perform`
/// bodies. Views should never touch it.
@MainActor
final class IntentAppState {

    /// Process-global shared instance.
    static let shared = IntentAppState()

    /// Current directory listing; refreshed each `allVMs` call so
    /// users see VMs created while the intent extension was alive.
    private var cache: [String: VirtualMachineBundle] = [:]

    private init() {}

    // MARK: - Queries

    /// All VMs currently on disk, sorted by name.
    func allVMs() -> [VMEntity] {
        refresh()
        return cache.keys.sorted().map {
            VMEntity(id: $0, displayName: $0)
        }
    }

    /// Resolve VM entities by ID for the intents system.
    func vms(named ids: [String]) -> [VMEntity] {
        refresh()
        return ids.compactMap { id in
            cache[id].map { _ in VMEntity(id: id, displayName: id) }
        }
    }

    // MARK: - Operations

    /// Starts the named VM. Mirrors ``AppState/startVM(_:)``
    /// without the UI-only side effects.
    func startVM(_ name: String) async {
        refresh()
        guard let bundle = cache[name] else { return }
        do {
            let vm = try VirtualMachine(bundle: bundle)
            try await vm.start()
        } catch {
            Log.vm.error("Intent StartVM failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the named VM by sending SIGTERM to its PID file.
    /// Works whether or not this process is the owner.
    func stopVM(_ name: String) async {
        guard let bundleURL = try? SpooktacularPaths.bundleURL(for: name),
              let pid = PIDFile.read(from: bundleURL) else { return }
        kill(pid, SIGTERM)
    }

    /// Takes a snapshot. VM must be stopped.
    func snapshotVM(_ name: String, label: String) async throws {
        refresh()
        guard let bundle = cache[name] else {
            throw IntentError.vmNotFound(name)
        }
        try SnapshotManager.save(bundle: bundle, label: label)
    }

    /// Restores a snapshot. VM must be stopped.
    func restoreVM(_ name: String, label: String) async throws {
        refresh()
        guard let bundle = cache[name] else {
            throw IntentError.vmNotFound(name)
        }
        try SnapshotManager.restore(bundle: bundle, label: label)
    }

    /// Clones a VM.
    func cloneVM(_ source: String, to destination: String) async {
        refresh()
        guard let sourceBundle = cache[source],
              let destinationURL = try? SpooktacularPaths.bundleURL(for: destination) else { return }
        _ = try? CloneManager.clone(source: sourceBundle, to: destinationURL)
    }

    /// Runs a command inside a running VM and returns stdout.
    ///
    /// Routes through the guest agent's vsock interface so the
    /// intent works even when the app isn't in the foreground.
    /// Requires a responsive guest agent.
    func runCommand(_ command: String, in name: String) async throws -> String {
        refresh()
        guard let bundle = cache[name] else {
            throw IntentError.vmNotFound(name)
        }
        let vm = try VirtualMachine(bundle: bundle)
        guard let client = vm.makeGuestAgentClient() else {
            throw IntentError.noGuestAgent
        }
        let result = try await client.run(command)
        return result.stdout
    }

    // MARK: - Helpers

    private func refresh() {
        do {
            try SpooktacularPaths.ensureDirectories()
            let contents = try FileManager.default.contentsOfDirectory(
                at: SpooktacularPaths.vms,
                includingPropertiesForKeys: nil
            )
            var loaded: [String: VirtualMachineBundle] = [:]
            for url in contents where url.pathExtension == "vm" {
                let name = url.deletingPathExtension().lastPathComponent
                if let bundle = try? VirtualMachineBundle.load(from: url) {
                    loaded[name] = bundle
                }
            }
            cache = loaded
        } catch {
            Log.vm.error("IntentAppState refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Errors surfaced from App Intents. All conform to
/// `LocalizedError` so the system renders them in the Shortcuts
/// UI without extra wiring.
enum IntentError: LocalizedError {
    case vmNotFound(String)
    case noGuestAgent

    var errorDescription: String? {
        switch self {
        case .vmNotFound(let name):
            "No virtual machine named '\(name)'."
        case .noGuestAgent:
            "The workspace has no guest agent reachable over vsock. Ensure the VM is running and spooktacular-agent is installed."
        }
    }
}

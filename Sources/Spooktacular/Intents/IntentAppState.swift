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

    /// Current directory listing, keyed by bundle UUID string (see
    /// ``refresh()``) — never by display name. Refreshed each
    /// `allVMs` call so users see VMs created while the intent
    /// extension was alive.
    private var cache: [String: VirtualMachineBundle] = [:]

    private init() {}

    // MARK: - Queries

    /// All VMs currently on disk, sorted by display name.
    ///
    /// `cache` is keyed by the bundle's UUID string (matching its
    /// on-disk `<uuid>.vm` directory basename — see ``refresh()``),
    /// never by display name, so ``VMEntity/id`` must come from the
    /// dictionary key while ``VMEntity/displayName`` comes from
    /// ``VirtualMachineBundle/displayName``. Mirrors the same
    /// UUID-key / display-name split ``AppState/vms`` and
    /// `Dictionary.key(forDisplayName:)` resolve for the GUI (see
    /// that extension's doc comment) — Shortcuts users pick VMs by
    /// the label they typed at create time, not by a raw UUID.
    func allVMs() -> [VMEntity] {
        refresh()
        return cache
            .map { key, bundle in VMEntity(id: key, displayName: bundle.displayName) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Resolve VM entities by ID for the intents system.
    ///
    /// `ids` are ``VMEntity/id`` values Shortcuts already holds —
    /// i.e. `cache` keys (bundle UUID strings) — round-tripped back
    /// from a previously-run ``allVMs()``/``vms(named:)`` call. See
    /// ``allVMs()``'s doc comment for the key/display-name split.
    func vms(named ids: [String]) -> [VMEntity] {
        refresh()
        return ids.compactMap { id in
            cache[id].map { bundle in VMEntity(id: id, displayName: bundle.displayName) }
        }
    }

    // MARK: - Operations

    /// Starts the named VM. Mirrors ``AppState/startVM(_:)``
    /// without the UI-only side effects.
    ///
    /// Throws on failure so `AppIntent.perform()` surfaces the
    /// error in the Shortcuts UI instead of silently succeeding.
    func startVM(_ name: String) async throws {
        refresh()
        guard let bundle = cache[name] else {
            throw IntentError.vmNotFound(name)
        }
        do {
            let vm = try VirtualMachine(bundle: bundle)
            try await vm.start()
        } catch {
            Log.vm.error("Intent StartVM failed: \(error.localizedDescription, privacy: .public)")
            throw IntentError.startFailed(name: name, reason: error.localizedDescription)
        }
    }

    /// Stops the named VM by sending SIGTERM to its PID file.
    /// Works whether or not this process is the owner.
    ///
    /// Throws when the VM is unknown or no PID file can be read,
    /// so Shortcuts can present a meaningful "couldn't stop" step.
    func stopVM(_ name: String) async throws {
        guard let bundleURL = try? SpooktacularPaths.resolveBundle(selector: name) else {
            throw IntentError.vmNotFound(name)
        }
        guard let pid = PIDFile.read(from: bundleURL) else {
            throw IntentError.notRunning(name)
        }
        if kill(pid, SIGTERM) != 0 {
            throw IntentError.stopFailed(name: name, reason: "kill(\(pid), SIGTERM) returned \(errno)")
        }
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

    /// Clones a VM. Throws on failure so the Shortcuts user sees
    /// a clear error rather than a silent no-op.
    func cloneVM(_ source: String, to destination: String) async throws {
        refresh()
        guard let sourceBundle = cache[source] else {
            throw IntentError.vmNotFound(source)
        }
        let destinationID = UUID()
        let destinationURL = SpooktacularPaths.bundleURL(for: destinationID)
        _ = try CloneManager.clone(
            source: sourceBundle,
            to: destinationURL,
            displayName: destination
        )
    }

    // MARK: - Helpers

    /// Rebuilds ``cache`` from every `.vm` bundle on disk, keyed by
    /// the bundle's UUID string — `VirtualMachineBundle.load(from:)`
    /// migrates any legacy display-name-keyed directory to
    /// `<uuid>.vm` before returning, so the basename here is always
    /// the UUID, never the user-facing label (that lives at
    /// `bundle.displayName`). Matches `AppState.loadVMs()`'s
    /// identical on-disk scan for the GUI's `vms` dictionary.
    private func refresh() {
        do {
            try SpooktacularPaths.ensureDirectories()
            let contents = try FileManager.default.contentsOfDirectory(
                at: SpooktacularPaths.vms,
                includingPropertiesForKeys: nil
            )
            var loaded: [String: VirtualMachineBundle] = [:]
            for url in contents where url.pathExtension == "vm" {
                let key = url.deletingPathExtension().lastPathComponent
                if let bundle = try? VirtualMachineBundle.load(from: url) {
                    loaded[key] = bundle
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
    case startFailed(name: String, reason: String)
    case stopFailed(name: String, reason: String)
    case notRunning(String)

    var errorDescription: String? {
        switch self {
        case .vmNotFound(let name):
            "No virtual machine named '\(name)'."
        case .startFailed(let name, let reason):
            "Could not start '\(name)': \(reason)"
        case .stopFailed(let name, let reason):
            "Could not stop '\(name)': \(reason)"
        case .notRunning(let name):
            "Virtual machine '\(name)' is not running."
        }
    }
}

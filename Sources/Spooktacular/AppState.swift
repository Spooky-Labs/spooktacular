import SwiftUI
import os
import SpooktacularKit

/// The shared application state for Spooktacular.
///
/// `AppState` tracks all known VM bundles, running VM instances,
/// selected state, and user-facing errors. Views observe it via
/// the SwiftUI `@Environment`.
///
/// All error-producing operations surface errors through
/// ``errorMessage`` and ``errorPresented``, which drives a
/// centralized alert in the root view. This ensures the same
/// error presentation behavior across all user interactions.
@Observable
@MainActor
final class AppState {

    // MARK: - VM Management

    /// All known VM bundles, keyed by name.
    var vms: [String: VirtualMachineBundle] = [:]

    /// The currently selected VM name in the sidebar.
    var selectedVM: String?

    /// Running VM instances, keyed by name.
    var runningVMs: [String: VirtualMachine] = [:]

    // MARK: - Error Handling

    /// A user-facing error message for the centralized alert.
    var errorMessage: String?

    /// Whether the error alert is presented.
    var errorPresented: Bool = false

    // MARK: - Sheet Presentation

    /// Whether the "Create VM" sheet is showing.
    var showCreateSheet = false

    /// Whether the "Add Image" sheet is showing.
    var showAddImage = false

    // MARK: - Image Library

    /// The local cache of VM images (IPSWs + OCI).
    let imageLibrary = ImageLibrary(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".spooktacular")
            .appendingPathComponent("images")
    )

    // MARK: - Paths

    /// Root data directory: `~/.spooktacular/`.
    let rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".spooktacular")

    /// VM bundles directory: `~/.spooktacular/vms/`.
    var vmsDirectory: URL {
        rootDirectory.appendingPathComponent("vms")
    }

    /// IPSW cache directory: `~/.spooktacular/cache/ipsw/`.
    var ipswCacheDirectory: URL {
        rootDirectory.appendingPathComponent("cache")
            .appendingPathComponent("ipsw")
    }

    // MARK: - Lifecycle

    /// Scans the VM directory, loads all bundles, and refreshes
    /// the image library.
    func loadVMs() {
        imageLibrary.load()

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: vmsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: ipswCacheDirectory, withIntermediateDirectories: true)

            let contents = try fileManager.contentsOfDirectory(
                at: vmsDirectory,
                includingPropertiesForKeys: nil
            )

            var loaded: [String: VirtualMachineBundle] = [:]
            for url in contents where url.pathExtension == "vm" {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let bundle = try VirtualMachineBundle.load(from: url)
                    loaded[name] = bundle
                } catch {
                    Log.vm.error("Failed to load bundle '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                }
            }
            vms = loaded
        } catch {
            presentError(error)
        }
    }

    /// Whether a VM is currently running.
    func isRunning(_ name: String) -> Bool {
        runningVMs[name] != nil
    }

    /// Starts a VM by name.
    func startVM(_ name: String) async {
        guard let bundle = vms[name], runningVMs[name] == nil else { return }

        do {
            let vm = try VirtualMachine(bundle: bundle)
            try await vm.start()
            runningVMs[name] = vm

            AccessibilityNotification.Announcement(
                "Virtual machine \(name) started"
            ).post()
        } catch {
            presentError(error)
        }
    }

    /// Stops a VM by name.
    func stopVM(_ name: String) async {
        guard let vm = runningVMs[name] else { return }

        do {
            try await vm.stop(graceful: false)
            runningVMs.removeValue(forKey: name)

            AccessibilityNotification.Announcement(
                "Virtual machine \(name) stopped"
            ).post()
        } catch {
            presentError(error)
        }
    }

    /// Deletes a VM by name, stopping it first if running.
    func deleteVM(_ name: String) {
        Task {
            do {
                // Stop the VM before deleting its bundle.
                if let vm = runningVMs.removeValue(forKey: name) {
                    Log.vm.info("Stopping running VM '\(name, privacy: .public)' before deletion")
                    try await vm.stop(graceful: false)
                }
                if let bundle = vms.removeValue(forKey: name) {
                    try FileManager.default.removeItem(at: bundle.url)
                }
                if selectedVM == name {
                    selectedVM = nil
                }

                AccessibilityNotification.Announcement(
                    "Virtual machine \(name) deleted"
                ).post()
            } catch {
                presentError(error)
            }
        }
    }

    /// Clones a VM.
    func cloneVM(_ source: String, to destination: String) {
        do {
            guard let sourceBundle = vms[source] else { return }
            let destinationURL = vmsDirectory.appendingPathComponent("\(destination).vm")
            let clone = try CloneManager.clone(source: sourceBundle, to: destinationURL)
            vms[destination] = clone

            AccessibilityNotification.Announcement(
                "Virtual machine \(source) cloned to \(destination)"
            ).post()
        } catch {
            presentError(error)
        }
    }

    // MARK: - Private

    /// Surfaces an error to the user through the centralized alert.
    private func presentError(_ error: Error) {
        Log.ui.error("Presenting error to user: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
        errorPresented = true
    }
}

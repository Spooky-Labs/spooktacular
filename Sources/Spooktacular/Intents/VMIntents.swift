import AppIntents
import SwiftUI
import SpooktacularKit

/// Exposes Spooktacular's lifecycle operations to the system
/// intents subsystem — Shortcuts, Spotlight, Siri, Focus filters,
/// Universal Control, Handoff.
///
/// Each intent is a thin wrapper over an existing ``AppState``
/// method; all side effects still go through the application
/// layer so RBAC, audit, and tenant-isolation enforcement stays
/// consistent with the CLI and HTTP API paths. No duplicate
/// lifecycle logic.
///
/// The `AppShortcutsProvider` at the bottom registers natural-
/// language phrases so `"Hey Siri, start runner-01"` works out of
/// the box after first launch.

// MARK: - Query

/// Suggests VM names in Shortcuts parameter pickers.
///
/// `VMQuery` returns the currently-loaded VMs so users don't type
/// names by hand. Re-runs when the VM list changes since AppState
/// reloads on create/delete — Shortcuts caches per-session.
struct VMQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [VMEntity] {
        let state = await IntentAppState.shared
        return await state.vms(named: identifiers)
    }

    func suggestedEntities() async throws -> [VMEntity] {
        let state = await IntentAppState.shared
        return await state.allVMs()
    }
}

// MARK: - Entity

/// The VM as a typed entity visible to the intents system.
struct VMEntity: AppEntity {
    let id: String
    let displayName: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Virtual Machine"
    )

    static let defaultQuery = VMQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

// MARK: - Intents

/// Starts a VM.
struct StartVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Virtual Machine"
    static let description = IntentDescription(
        "Start a Spooktacular workspace and wait for it to boot.",
        searchKeywords: ["boot", "run", "launch", "VM"]
    )

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await IntentAppState.shared.startVM(vm.id)
        return .result(value: vm.id)
    }
}

/// Stops a VM.
struct StopVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Virtual Machine"
    static let description = IntentDescription(
        "Stop a running Spooktacular workspace.",
        searchKeywords: ["halt", "quit", "shut down", "VM"]
    )

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Stop \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await IntentAppState.shared.stopVM(vm.id)
        return .result(value: vm.id)
    }
}

/// Takes a snapshot of a stopped VM.
struct SnapshotVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Snapshot Virtual Machine"
    static let description = IntentDescription(
        "Take a named disk snapshot of a stopped workspace."
    )

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Label")
    var label: String

    static var parameterSummary: some ParameterSummary {
        Summary("Snapshot \(\.$vm) as \(\.$label)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentAppState.shared.snapshotVM(vm.id, label: label)
        return .result()
    }
}

/// Restores a VM to a prior snapshot.
struct RestoreVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Restore Virtual Machine"
    static let description = IntentDescription(
        "Restore a stopped workspace to a named snapshot."
    )

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Label")
    var label: String

    static var parameterSummary: some ParameterSummary {
        Summary("Restore \(\.$vm) to \(\.$label)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentAppState.shared.restoreVM(vm.id, label: label)
        return .result()
    }
}

/// Clones a VM.
struct CloneVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Clone Virtual Machine"
    static let description = IntentDescription(
        "APFS-clone a workspace under a new name."
    )

    @Parameter(title: "Source")
    var source: VMEntity

    @Parameter(title: "Destination name")
    var destination: String

    static var parameterSummary: some ParameterSummary {
        Summary("Clone \(\.$source) as \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentAppState.shared.cloneVM(source.id, to: destination)
        return .result()
    }
}

/// Runs a shell command inside a VM via the guest agent.
struct RunCommandInVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command in Virtual Machine"
    static let description = IntentDescription(
        "Execute a shell command inside a running workspace and return stdout."
    )

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Command")
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) in \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await IntentAppState.shared.runCommand(command, in: vm.id)
        return .result(value: output)
    }
}

// MARK: - App Shortcuts

/// Registers natural-language phrases for each intent so users
/// can say `"Hey Siri, start runner-01"` without opening the app.
///
/// Phrases need at least one `.applicationName` placeholder to
/// avoid false-positive activation of other apps' intents.
struct SpooktacularShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVMIntent(),
            phrases: [
                "Start a workspace in \(.applicationName)",
                "Start \(\.$vm) in \(.applicationName)",
            ],
            shortTitle: "Start Workspace",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopVMIntent(),
            phrases: [
                "Stop \(\.$vm) in \(.applicationName)",
            ],
            shortTitle: "Stop Workspace",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: SnapshotVMIntent(),
            phrases: [
                "Snapshot \(\.$vm) in \(.applicationName)",
            ],
            shortTitle: "Snapshot Workspace",
            systemImageName: "camera.fill"
        )
    }
}

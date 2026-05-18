import Foundation
import SpooktacularCore
import SpooktacularApplication
import SpooktacularInfrastructureApple

/// Minimum-viable embedding example: load an existing VM bundle, boot
/// it, wait for it to run, then request a graceful stop.
///
/// Run with:
///
///     swift run VMLifecycle <vm-name>
///
/// This is the "reference architecture in one file" — read it top to
/// bottom to see how `SpooktacularCore`, `SpooktacularApplication`, and
/// `SpooktacularInfrastructureApple` compose without any other dependency.
/// For the full create-from-IPSW flow, see ``RestoreImageManager``'s
/// documentation — the `spook create` CLI command is the canonical
/// caller.
@main
@MainActor
struct VMLifecycleExample {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: VMLifecycle <vm-name>")
            print("Tip: create a VM with 'spook create <name>' first.")
            exit(EXIT_FAILURE)
        }
        let vmName = args[1]

        let bundleURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: ".spooktacular/vms")
            .appending(path: "\(vmName).vm")

        // ── Step 1: Load the on-disk VM bundle. Parses config.json
        //           and metadata.json from the `.vm` directory.
        let bundle = try VirtualMachineBundle.load(from: bundleURL)
        print("Loaded '\(vmName)': \(bundle.spec.cpuCount) CPU, \(bundle.spec.memorySizeInGigabytes) GB RAM")

        // ── Step 2: Build the `VirtualMachine` — `@MainActor`-isolated
        //           class that wraps `VZVirtualMachine` with a typed
        //           state machine and delegate bridging.
        let vm = try VirtualMachine(bundle: bundle)

        // ── Step 3: Subscribe to state changes. The stream yields every
        //           transition — start here to observe without polling.
        Task { @MainActor in
            for await state in vm.stateStream {
                print("  state → \(state)")
            }
        }

        // ── Step 4: Boot it. Transitions stopped → starting → running.
        try await vm.start()
        print("VM is running.")

        // ── Step 5: Hold open for the demo then request a graceful stop.
        try await Task.sleep(for: .seconds(60))
        try await vm.stop(graceful: true)
        print("VM stopped cleanly.")
    }
}

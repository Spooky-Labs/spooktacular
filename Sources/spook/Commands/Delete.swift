import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Deletes a virtual machine and its bundle.
    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a VM and all its data.",
            discussion: """
                Permanently removes a VM bundle including its disk image, \
                configuration, and any saved snapshots. This cannot be undone.

                A running VM cannot be deleted unless --force is used, which \
                stops the VM first.

                EXAMPLES:
                  spook delete my-vm
                  spook delete runner-01 --force
                """
        )

        @Argument(help: "Name of the VM to delete.")
        var name: String

        @Flag(help: "Stop a running VM before deleting, and skip confirmation prompt.")
        var force: Bool = false

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            // Prevent deleting a running VM unless --force is used.
            if PIDFile.isRunning(bundleURL: bundleURL) {
                if force {
                    print(Style.info("Stopping VM '\(name)'..."))
                    let savedPID = PIDFile.read(from: bundleURL)
                    await PIDFile.terminate(bundleURL: bundleURL)

                    // Verify the process actually died before deleting.
                    if let pid = savedPID, PIDFile.isProcessAlive(pid) {
                        print(Style.error("Process \(pid) is still alive after termination."))
                        print(Style.dim("  Cannot safely delete the VM while its process is running."))
                        throw ExitCode.failure
                    }

                    print(Style.success("✓ VM '\(name)' stopped."))
                } else {
                    print(Style.error("Cannot delete '\(name)': VM is currently running."))
                    print(Style.dim("Stop it first with: spook stop \(name)"))
                    throw ExitCode.failure
                }
            }

            if !force {
                print(
                    Style.warning("⚠ Delete VM '\(name)' and all its data?")
                    + " [y/N] ",
                    terminator: ""
                )
                fflush(stdout)
                guard let response = readLine(), response.lowercased() == "y" else {
                    print(Style.dim("Cancelled."))
                    return
                }
            }

            try FileManager.default.removeItem(at: bundleURL)
            print(Style.success("✓ VM '\(name)' deleted."))
        }
    }
}

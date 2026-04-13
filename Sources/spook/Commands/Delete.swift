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
                    // Stop the VM by sending SIGTERM to the owning process.
                    if let pid = PIDFile.read(from: bundleURL) {
                        print(Style.info("Stopping VM '\(name)' (PID \(pid))..."))
                        kill(pid, SIGTERM)

                        // Wait briefly for the process to exit.
                        let deadline = Date().addingTimeInterval(10)
                        while PIDFile.isProcessAlive(pid), Date() < deadline {
                            try await Task.sleep(nanoseconds: 500_000_000)
                        }

                        // If still alive after timeout, force-kill.
                        if PIDFile.isProcessAlive(pid) {
                            kill(pid, SIGKILL)
                            try await Task.sleep(nanoseconds: 500_000_000)
                        }

                        PIDFile.remove(from: bundleURL)
                        print(Style.success("✓ VM '\(name)' stopped."))
                    }
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

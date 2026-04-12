import ArgumentParser
import Foundation

extension Spook {

    /// Deletes a virtual machine and its bundle.
    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a VM and all its data.",
            discussion: """
                Permanently removes a VM bundle including its disk image, \
                configuration, and any saved snapshots. This cannot be undone.

                EXAMPLES:
                  spook delete my-vm
                  spook delete runner-01 --force
                """
        )

        @Argument(help: "Name of the VM to delete.")
        var name: String

        @Flag(help: "Skip confirmation prompt.")
        var force: Bool = false

        func run() async throws {
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print(Style.error("✗ VM '\(name)' not found.") + Style.dim(" Run 'spook list' to see available VMs."))
                throw ExitCode.failure
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

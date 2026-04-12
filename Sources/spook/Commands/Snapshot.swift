import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Manages VM snapshots.
    struct Snapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a VM's state as a named snapshot.",
            discussion: """
                Saves the current state of a virtual machine as a \
                named snapshot. Snapshots capture the full VM state \
                (memory + disk) and can be restored later with \
                'spook restore'.

                EXAMPLES:
                  spook snapshot my-vm clean-install
                  spook snapshot runner before-xcode
                """,
            subcommands: [],
            aliases: []
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Label for this snapshot.")
        var label: String

        func run() async throws {
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found. Run 'spook list' to see available VMs.")
                throw ExitCode.failure
            }

            // Snapshots require saving the full VM state (memory + disk).
            // This will be implemented with VZVirtualMachine.saveMachineStateTo
            // once the VM lifecycle daemon is in place.
            print("Saving snapshot '\(label)' for VM '\(name)'...")
            print("(Snapshot support requires the VM lifecycle daemon, coming soon.)")
        }
    }

    /// Restores a VM to a previously saved snapshot.
    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore a VM to a saved snapshot.",
            discussion: """
                Restores a virtual machine to the state captured by a \
                previous snapshot. The VM must be stopped before restoring.

                EXAMPLES:
                  spook restore my-vm clean-install
                  spook restore runner before-xcode
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Label of the snapshot to restore.")
        var label: String

        func run() async throws {
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found. Run 'spook list' to see available VMs.")
                throw ExitCode.failure
            }

            let savedStatesDir = bundleURL.appendingPathComponent("SavedStates")
            let snapshotDir = savedStatesDir.appendingPathComponent(label)

            guard FileManager.default.fileExists(atPath: snapshotDir.path) else {
                print("Error: Snapshot '\(label)' not found for VM '\(name)'.")
                print("Run 'spook snapshots \(name)' to see available snapshots.")
                throw ExitCode.failure
            }

            print("Restoring VM '\(name)' to snapshot '\(label)'...")
            print("(Snapshot restore requires the VM lifecycle daemon, coming soon.)")
        }
    }

    /// Lists all snapshots for a VM.
    struct Snapshots: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List snapshots for a VM.",
            discussion: """
                Lists all saved snapshots for the specified virtual \
                machine. Each snapshot shows its label and creation date.

                EXAMPLES:
                  spook snapshots my-vm
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        func run() async throws {
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found. Run 'spook list' to see available VMs.")
                throw ExitCode.failure
            }

            let savedStatesDir = bundleURL.appendingPathComponent("SavedStates")
            let fm = FileManager.default

            guard fm.fileExists(atPath: savedStatesDir.path),
                  let contents = try? fm.contentsOfDirectory(
                    at: savedStatesDir,
                    includingPropertiesForKeys: [.creationDateKey]
                  ),
                  !contents.isEmpty
            else {
                print("No snapshots found for VM '\(name)'.")
                print("Run 'spook snapshot \(name) <label>' to create one.")
                return
            }

            print("Snapshots for '\(name)':")
            print(String(repeating: "─", count: 40))
            for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let label = entry.lastPathComponent
                let values = try? entry.resourceValues(forKeys: [.creationDateKey])
                let date = values?.creationDate.map { "\($0)" } ?? "unknown"
                print("  \(label)  (\(date))")
            }
        }
    }
}

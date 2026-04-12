import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Saves a disk-level snapshot of a VM.
    struct Snapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a VM's disk state as a named snapshot.",
            discussion: """
                Copies the VM's disk image and auxiliary storage into \
                a named snapshot directory. The VM must be stopped \
                before snapshotting.

                Snapshots are stored in SavedStates/<label>/ inside \
                the VM bundle. Restore with 'spook restore'.

                EXAMPLES:
                  spook snapshot my-vm clean-install
                  spook snapshot runner before-xcode
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Label for this snapshot.")
        var label: String

        func run() async throws {
            let bundleURL = try Paths.requireBundle(for: name)

            guard !PIDFile.isRunning(bundleURL: bundleURL) else {
                print(Style.error("✗ VM '\(name)' is currently running."))
                print(Style.dim("  Stop the VM first with 'spook stop \(name)'."))
                throw ExitCode.failure
            }

            let bundle = try VirtualMachineBundle.load(from: bundleURL)

            print("Saving snapshot '\(label)' for VM '\(name)'...")

            do {
                try SnapshotManager.save(bundle: bundle, label: label)
            } catch let error as SnapshotError {
                print(Style.error("✗ \(error.localizedDescription)"))
                if let recovery = error.recoverySuggestion {
                    print(Style.dim("  \(recovery)"))
                }
                throw ExitCode.failure
            }

            let snapshots = try SnapshotManager.list(bundle: bundle)
            if let info = snapshots.first(where: { $0.label == label }) {
                let sizeMB = Double(info.sizeInBytes) / (1024 * 1024)
                print(Style.success("✓ Snapshot '\(label)' saved (\(String(format: "%.1f", sizeMB)) MB)."))
            } else {
                print(Style.success("✓ Snapshot '\(label)' saved."))
            }
        }
    }

    /// Restores a VM to a previously saved snapshot.
    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore a VM to a saved snapshot.",
            discussion: """
                Replaces the VM's disk image and auxiliary storage \
                with the copies from a previously saved snapshot. \
                The VM must be stopped before restoring.

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
            let bundleURL = try Paths.requireBundle(for: name)

            guard !PIDFile.isRunning(bundleURL: bundleURL) else {
                print(Style.error("✗ VM '\(name)' is currently running."))
                print(Style.dim("  Stop the VM first with 'spook stop \(name)'."))
                throw ExitCode.failure
            }

            let bundle = try VirtualMachineBundle.load(from: bundleURL)

            print("Restoring VM '\(name)' to snapshot '\(label)'...")

            do {
                try SnapshotManager.restore(bundle: bundle, label: label)
            } catch let error as SnapshotError {
                print(Style.error("✗ \(error.localizedDescription)"))
                if let recovery = error.recoverySuggestion {
                    print(Style.dim("  \(recovery)"))
                }
                throw ExitCode.failure
            }

            print(Style.success("✓ VM '\(name)' restored to snapshot '\(label)'."))
        }
    }

    /// Lists all snapshots for a VM.
    struct Snapshots: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List snapshots for a VM.",
            discussion: """
                Lists all saved snapshots for the specified virtual \
                machine, showing label, creation date, and size.

                EXAMPLES:
                  spook snapshots my-vm
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        func run() async throws {
            let bundleURL = try Paths.requireBundle(for: name)

            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            let snapshots = try SnapshotManager.list(bundle: bundle)

            guard !snapshots.isEmpty else {
                print("No snapshots found for VM '\(name)'.")
                print("Run 'spook snapshot \(name) <label>' to create one.")
                return
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            var rows: [[String]] = []
            for info in snapshots {
                let sizeMB = String(format: "%.1f MB", Double(info.sizeInBytes) / (1024 * 1024))
                let date = dateFormatter.string(from: info.createdAt)
                rows.append([info.label, date, sizeMB])
            }

            Style.table(headers: ["LABEL", "DATE", "SIZE"], rows: rows)
        }
    }
}

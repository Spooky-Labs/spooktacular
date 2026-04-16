import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Disk-level snapshot management for VMs.
    ///
    /// Groups save/restore/list/delete under a single noun so the CLI
    /// surface matches the Docker/git-stash mental model:
    ///
    /// ```
    /// spook snapshot save my-vm clean-install
    /// spook snapshot list my-vm
    /// spook snapshot restore my-vm clean-install
    /// spook snapshot delete my-vm clean-install
    /// ```
    ///
    /// With no subcommand, behaves like `spook snapshot list`.
    struct Snapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage VM disk snapshots.",
            subcommands: [
                SnapshotSave.self,
                SnapshotRestore.self,
                SnapshotList.self,
                SnapshotDelete.self,
            ],
            defaultSubcommand: SnapshotList.self
        )
    }

    /// `spook snapshot save <vm> <label>`
    struct SnapshotSave: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "save",
            abstract: "Save a VM's disk state as a named snapshot.",
            discussion: """
                Copies the VM's disk image and auxiliary storage into a \
                named snapshot directory. The VM must be stopped before \
                snapshotting.

                Snapshots live in SavedStates/<label>/ inside the VM \
                bundle. Restore with 'spook snapshot restore'.

                EXAMPLES:
                  spook snapshot save my-vm clean-install
                  spook snapshot save runner before-xcode
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Label for this snapshot.")
        var label: String

        @Flag(name: [.short, .long], help: "Print verbose progress.")
        var verbose: Bool = false

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            guard !PIDFile.isRunning(bundleURL: bundleURL) else {
                print(Style.error("✗ VM '\(name)' is currently running."))
                print(Style.dim("  Stop the VM first with 'spook stop \(name)'."))
                throw ExitCode.failure
            }

            let bundle = try VirtualMachineBundle.load(from: bundleURL)

            print(Style.info("Saving snapshot '\(label)' for VM '\(name)'..."))

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
                print(Style.success("✓ Snapshot '\(label)' saved (\(humanizeBytes(info.sizeInBytes)))."))
            } else {
                print(Style.success("✓ Snapshot '\(label)' saved."))
            }
        }
    }

    /// `spook snapshot restore <vm> <label>`
    struct SnapshotRestore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore",
            abstract: "Restore a VM to a saved snapshot.",
            discussion: """
                Replaces the VM's disk image and auxiliary storage with \
                copies from a previously saved snapshot. The VM must be \
                stopped before restoring.

                EXAMPLES:
                  spook snapshot restore my-vm clean-install
                  spook snapshot restore runner before-xcode
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Label of the snapshot to restore.")
        var label: String

        @Flag(name: [.customLong("dry-run")], help: "Show what would be restored without doing it.")
        var dryRun: Bool = false

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            guard !PIDFile.isRunning(bundleURL: bundleURL) else {
                print(Style.error("✗ VM '\(name)' is currently running."))
                print(Style.dim("  Stop the VM first with 'spook stop \(name)'."))
                throw ExitCode.failure
            }

            let bundle = try VirtualMachineBundle.load(from: bundleURL)

            if dryRun {
                let snapshots = try SnapshotManager.list(bundle: bundle)
                guard let info = snapshots.first(where: { $0.label == label }) else {
                    print(Style.error("✗ No snapshot labeled '\(label)' for VM '\(name)'."))
                    throw ExitCode.failure
                }
                print(Style.info("[dry-run] Would restore VM '\(name)' to snapshot '\(info.label)' (\(humanizeBytes(info.sizeInBytes)))."))
                return
            }

            print(Style.info("Restoring VM '\(name)' to snapshot '\(label)'..."))

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

    /// `spook snapshot list <vm>`
    struct SnapshotList: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List snapshots for a VM."
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Flag(name: [.short, .long], help: "Emit JSON instead of a table.")
        var json: Bool = false

        func run() async throws {
            let bundleURL = try requireBundle(for: name)
            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            let snapshots = try SnapshotManager.list(bundle: bundle)

            if json {
                struct Row: Encodable { let label: String; let createdAt: Date; let sizeBytes: UInt64 }
                let rows = snapshots.map { Row(label: $0.label, createdAt: $0.createdAt, sizeBytes: $0.sizeInBytes) }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(rows)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            guard !snapshots.isEmpty else {
                print(Style.dim("No snapshots found for VM '\(name)'."))
                print(Style.dim("Run 'spook snapshot save \(name) <label>' to create one."))
                return
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            let rows = snapshots.map { info in
                [info.label, dateFormatter.string(from: info.createdAt), humanizeBytes(info.sizeInBytes)]
            }
            Style.table(headers: ["LABEL", "DATE", "SIZE"], rows: rows)
        }
    }

    /// `spook snapshot delete <vm> <label>`
    struct SnapshotDelete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a saved snapshot.",
            discussion: """
                Removes the named snapshot from the VM bundle. This cannot \
                be undone. Use --dry-run to preview.
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Label of the snapshot to delete.")
        var label: String

        @Flag(name: [.customLong("dry-run")], help: "Show what would be deleted without doing it.")
        var dryRun: Bool = false

        func run() async throws {
            let bundleURL = try requireBundle(for: name)
            let bundle = try VirtualMachineBundle.load(from: bundleURL)

            if dryRun {
                print(Style.info("[dry-run] Would delete snapshot '\(label)' from VM '\(name)'."))
                return
            }

            do {
                try SnapshotManager.delete(bundle: bundle, label: label)
            } catch let error as SnapshotError {
                print(Style.error("✗ \(error.localizedDescription)"))
                throw ExitCode.failure
            }
            print(Style.success("✓ Snapshot '\(label)' deleted."))
        }
    }
}

/// Formats a byte count as KB/MB/GB/TB with one decimal place.
///
/// Used across CLI commands so output is readable for both tiny
/// snapshots (a few MB) and full disk images (tens of GB).
func humanizeBytes(_ bytes: UInt64) -> String {
    let value = Double(bytes)
    if value < 1024 {
        return "\(bytes) B"
    }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var size = value / 1024
    var unit = 0
    while size >= 1024 && unit < units.count - 1 {
        size /= 1024
        unit += 1
    }
    return String(format: "%.1f %@", size, units[unit])
}

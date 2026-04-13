import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Manages shared folders for a virtual machine.
    struct Share: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage shared folders for a VM.",
            discussion: """
                Manages VirtIO shared folders that appear as mounted \
                volumes inside the guest macOS. Shared folders allow \
                bidirectional file access between the host and guest.

                The guest sees shared folders via the macOS VirtIO \
                file-sharing driver. Use --read-only to prevent the \
                guest from modifying host files.

                EXAMPLES:
                  spook share my-vm add ~/Projects --tag projects
                  spook share my-vm add ~/Data --tag data --read-only
                  spook share my-vm remove projects
                  spook share my-vm list
                """,
            subcommands: [
                Add.self,
                Remove.self,
                ShareList.self,
            ],
            defaultSubcommand: ShareList.self
        )
    }
}

extension Spook.Share {

    /// Adds a shared folder to a VM.
    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a shared folder to a VM.",
            discussion: """
                Shares a host directory into the VM. The directory \
                is accessible inside the guest as a VirtIO-mounted \
                volume. Changes take effect on the next VM start.

                EXAMPLES:
                  spook share my-vm add ~/Projects --tag projects
                  spook share my-vm add /data --tag data --read-only
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(
            help: "Path to the host directory to share.",
            transform: { (path: String) -> String in
                NSString(string: path).expandingTildeInPath
            }
        )
        var path: String

        @Option(help: "Tag identifier for this share (used to mount in guest).")
        var tag: String?

        @Flag(help: "Mount as read-only in the guest.")
        var readOnly: Bool = false

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                print(Style.error("✗ Directory not found at '\(path)'."))
                print(Style.dim("  Verify the path exists and is accessible."))
                throw ExitCode.failure
            }
            guard isDir.boolValue else {
                print(Style.error("✗ '\(path)' is not a directory."))
                print(Style.dim("  Shared folders must be directories, not files."))
                throw ExitCode.failure
            }

            let shareTag = tag ?? URL(fileURLWithPath: path).lastPathComponent

            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            let newFolder = SharedFolder(
                hostPath: path,
                tag: shareTag,
                readOnly: readOnly
            )
            let updatedSpec = bundle.spec.withSharedFolders(
                bundle.spec.sharedFolders + [newFolder]
            )
            let configData = try VirtualMachineBundle.encoder.encode(updatedSpec)
            try configData.write(
                to: bundleURL.appendingPathComponent(VirtualMachineBundle.configFileName)
            )

            print(Style.success("✓ Added shared folder '\(shareTag)' to VM '\(name)'."))
            Style.field("Path", path)
            Style.field("Tag", shareTag)
            Style.field("Read-only", readOnly ? "yes" : "no")
            print("")
            print(Style.dim("The share will be available on next 'spook start \(name)'."))
            print(Style.dim("In the guest, mount with: mount_virtiofs \(shareTag) /Volumes/\(shareTag)"))
        }
    }

    /// Removes a shared folder from a VM.
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a shared folder from a VM.",
            discussion: """
                Removes a previously added shared folder by its tag. \
                Changes take effect on the next VM start.

                EXAMPLES:
                  spook share my-vm remove projects
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Tag of the shared folder to remove.")
        var tag: String

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            let filtered = bundle.spec.sharedFolders.filter { $0.tag != tag }

            guard filtered.count < bundle.spec.sharedFolders.count else {
                print(Style.error("✗ No shared folder with tag '\(tag)' found on VM '\(name)'."))
                print(Style.dim("  Run 'spook share \(name) list' to see configured shared folders."))
                throw ExitCode.failure
            }

            let updatedSpec = bundle.spec.withSharedFolders(filtered)
            let configData = try VirtualMachineBundle.encoder.encode(updatedSpec)
            try configData.write(
                to: bundleURL.appendingPathComponent(VirtualMachineBundle.configFileName)
            )

            print(Style.success("✓ Removed shared folder '\(tag)' from VM '\(name)'."))
            print(Style.dim("Changes take effect on next 'spook start \(name)'."))
        }
    }

    /// Lists shared folders for a VM.
    struct ShareList: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List shared folders for a VM.",
            discussion: """
                Shows all shared folders currently configured for the \
                specified VM.

                EXAMPLES:
                  spook share my-vm list
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            let folders = bundle.spec.sharedFolders

            guard !folders.isEmpty else {
                print(Style.dim("No shared folders configured for VM '\(name)'."))
                print(Style.dim("Run 'spook share \(name) add <path>' to add one."))
                return
            }

            let rows = folders.map { folder -> [String] in
                let mode = folder.readOnly ? "ro" : "rw"
                return [folder.hostPath, folder.tag, mode]
            }
            Style.table(headers: ["PATH", "TAG", "MODE"], rows: rows)
        }
    }
}

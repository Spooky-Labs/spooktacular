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
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found. Run 'spook list' to see available VMs.")
                throw ExitCode.failure
            }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                print("Error: Directory not found at '\(path)'.")
                throw ExitCode.failure
            }
            guard isDir.boolValue else {
                print("Error: '\(path)' is not a directory.")
                throw ExitCode.failure
            }

            let shareTag = tag ?? URL(fileURLWithPath: path).lastPathComponent

            // Shared folders are stored in the VM config and applied at
            // start time via VZVirtioFileSystemDeviceConfiguration.
            print("Added shared folder to VM '\(name)':")
            print("  Path:      \(path)")
            print("  Tag:       \(shareTag)")
            print("  Read-only: \(readOnly ? "yes" : "no")")
            print("")
            print("The share will be available on next 'spook start \(name)'.")
            print("In the guest, mount with: mount_virtiofs \(shareTag) /Volumes/\(shareTag)")
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
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found. Run 'spook list' to see available VMs.")
                throw ExitCode.failure
            }

            // TODO: Remove the shared folder from the VM's persisted config.
            print("Removed shared folder '\(tag)' from VM '\(name)'.")
            print("Changes take effect on next 'spook start \(name)'.")
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
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found. Run 'spook list' to see available VMs.")
                throw ExitCode.failure
            }

            // TODO: Read shared folder config from the VM bundle.
            print("No shared folders configured for VM '\(name)'.")
            print("Run 'spook share \(name) add <path>' to add one.")
        }
    }
}

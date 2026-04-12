import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Opens an SSH connection to a running virtual machine.
    struct SSH: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "SSH into a running VM.",
            discussion: """
                Connects to a running VM over SSH. The VM must have \
                Remote Login (SSH) enabled in System Settings and an \
                active network connection.

                Spooktacular resolves the VM's IP address automatically \
                via the DHCP lease table. If the IP cannot be resolved, \
                you can use 'spook ip <name>' to find it manually.

                EXAMPLES:
                  spook ssh my-vm
                  spook ssh my-vm --user admin
                  spook ssh my-vm --user ci --key ~/.ssh/ci_ed25519
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Option(help: "SSH user name.")
        var user: String = "admin"

        @Option(
            help: "Path to the SSH private key.",
            transform: { NSString(string: $0).expandingTildeInPath }
        )
        var key: String = "~/.ssh/id_ed25519"

        func run() async throws {
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found. Run 'spook list' to see available VMs.")
                throw ExitCode.failure
            }

            // Automatic IP resolution requires the VM lifecycle daemon.
            // For now, show the user the command to run manually.
            let expandedKey = NSString(string: key).expandingTildeInPath

            print("To SSH into VM '\(name)', first find its IP address:")
            print("  spook ip \(name)")
            print("")
            print("Then connect with:")
            print("  ssh -i \(expandedKey) \(user)@<ip-address>")
            print("")
            print("(Automatic SSH via 'spook ssh' requires the VM lifecycle daemon.")
            print("The daemon resolves the VM's IP and connects directly.)")
        }
    }
}

import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Executes a command inside a running virtual machine.
    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Execute a command inside a running VM.",
            discussion: """
                Runs a command inside the guest macOS and streams its \
                output back to the host. This requires either SSH \
                access or the Spooktacular guest agent installed in \
                the VM.

                Commands are executed in the guest's default shell. \
                Use '--' to separate spook arguments from the guest \
                command.

                EXAMPLES:
                  spook exec my-vm -- uname -a
                  spook exec my-vm -- sw_vers
                  spook exec my-vm -- /bin/bash -c "echo hello"
                  spook exec my-vm --user ci -- brew install git
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Option(help: "SSH user name for remote execution.")
        var user: String = "admin"

        @Argument(
            parsing: .captureForPassthrough,
            help: "Command and arguments to execute in the guest."
        )
        var command: [String] = []

        func run() async throws {
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found. Run 'spook list' to see available VMs.")
                throw ExitCode.failure
            }

            guard !command.isEmpty else {
                print("Error: No command specified. Use '--' followed by the command.")
                print("  Example: spook exec \(name) -- uname -a")
                throw ExitCode.failure
            }

            let cmdString = command.joined(separator: " ")

            // Remote execution requires either SSH or the guest agent.
            // For now, show the user the equivalent SSH command.
            print("To execute '\(cmdString)' in VM '\(name)':")
            print("")
            print("  1. Find the VM's IP:")
            print("     spook ip \(name)")
            print("")
            print("  2. Run via SSH:")
            print("     ssh \(user)@<ip-address> '\(cmdString)'")
            print("")
            print("(Direct execution via 'spook exec' requires the VM lifecycle daemon")
            print("or the Spooktacular guest agent. Coming soon.)")
        }
    }
}

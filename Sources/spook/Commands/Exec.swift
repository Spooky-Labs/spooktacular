import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Executes a command inside a running virtual machine.
    ///
    /// Resolves the VM's IP address, then runs the specified
    /// command over SSH. Standard output and error are streamed
    /// back to the host terminal.
    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Execute a command inside a running VM.",
            discussion: """
                Runs a command inside the guest macOS and streams its \
                output back to the host. The VM must have SSH (Remote \
                Login) enabled.

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

        @Option(
            help: "Path to the SSH private key.",
            transform: { NSString(string: $0).expandingTildeInPath }
        )
        var key: String = "~/.ssh/id_ed25519"

        @Argument(
            parsing: .captureForPassthrough,
            help: "Command and arguments to execute in the guest."
        )
        var command: [String] = []

        func run() async throws {
            let bundleURL = try Paths.requireBundle(for: name)

            guard !command.isEmpty else {
                print(Style.error("✗ No command specified."))
                print(Style.dim("  Use '--' followed by the command. Example: spook exec \(name) -- uname -a"))
                throw ExitCode.failure
            }

            guard PIDFile.isRunning(bundleURL: bundleURL) else {
                print(Style.error("✗ VM '\(name)' is not running."))
                print(Style.dim("  Start it with 'spook start \(name)'."))
                throw ExitCode.failure
            }

            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            let expandedKey = NSString(string: key).expandingTildeInPath
            let commandString = command.joined(separator: " ")

            guard let macAddress = bundle.spec.macAddress else {
                print(Style.error("✗ VM '\(name)' has no configured MAC address for automatic IP resolution."))
                print(Style.dim("  Find the IP manually, then run:"))
                print(Style.dim("  ssh \(user)@<ip-address> '\(commandString)'"))
                throw ExitCode.failure
            }

            guard let ip = try await IPResolver.resolveIP(macAddress: macAddress) else {
                print(Style.error("✗ Could not resolve IP for VM '\(name)'."))
                print(Style.dim("  The VM may still be booting. Try again in a few seconds."))
                throw ExitCode.failure
            }

            // Build the ssh command with the remote command appended.
            var args = SSHExecutor.sshOptions
            args += ["-i", expandedKey, "\(user)@\(ip)", commandString]

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = args
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                throw ExitCode(process.terminationStatus)
            }
        }
    }
}

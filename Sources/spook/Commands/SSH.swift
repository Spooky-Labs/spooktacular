import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Opens an SSH connection to a running virtual machine.
    ///
    /// Resolves the VM's IP address automatically via the DHCP
    /// lease table and ARP cache, then replaces the current
    /// process with an `ssh` connection.
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

            guard PIDFile.isRunning(bundleURL: bundleURL) else {
                print("Error: VM '\(name)' is not running. Start it with 'spook start \(name)'.")
                throw ExitCode.failure
            }

            let bundle = try VMBundle.load(from: bundleURL)
            let expandedKey = NSString(string: key).expandingTildeInPath

            guard let macAddress = bundle.spec.macAddress else {
                // Fall back to manual instructions if no MAC is set.
                print("VM '\(name)' has no configured MAC address for automatic IP resolution.")
                print("")
                print("Find the IP manually in the guest's System Settings > Network,")
                print("then connect with:")
                print("  ssh -i \(expandedKey) \(user)@<ip-address>")
                throw ExitCode.failure
            }

            guard let ip = try await IPResolver.resolveIP(macAddress: macAddress) else {
                print("Error: Could not resolve IP for VM '\(name)'.")
                print("The VM may still be booting. Try again in a few seconds.")
                throw ExitCode.failure
            }

            print("Connecting to \(user)@\(ip)...")

            // Build the ssh command and exec it, replacing this process.
            var args = SSHExecutor.sshOptions
            args += ["-i", expandedKey, "\(user)@\(ip)"]

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

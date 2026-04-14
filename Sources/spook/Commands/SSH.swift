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
            let bundleURL = try requireBundle(for: name)

            guard PIDFile.isRunning(bundleURL: bundleURL) else {
                print(Style.error("✗ VM '\(name)' is not running."))
                print(Style.dim("  Start it with 'spook start \(name)'."))
                throw ExitCode.failure
            }

            let bundle = try VirtualMachineBundle.load(from: bundleURL)

            guard let macAddress = bundle.spec.macAddress else {
                print(Style.error("✗ VM '\(name)' has no configured MAC address for automatic IP resolution."))
                print(Style.dim("  Find the IP manually in the guest's System Settings > Network,"))
                print(Style.dim("  then connect with:"))
                print(Style.dim("  ssh -i \(key) \(user)@<ip-address>"))
                throw ExitCode.failure
            }

            guard let ip = try await IPResolver.resolveIP(macAddress: macAddress) else {
                print(Style.error("✗ Could not resolve IP for VM '\(name)'."))
                print(Style.dim("  The VM may still be booting. Try again in a few seconds."))
                throw ExitCode.failure
            }

            print(Style.info("Connecting to \(user)@\(ip)..."))

            var args = SSHExecutor.sshOptions
            args += ["-i", key, "\(user)@\(ip)"]

            do {
                try SSHExecutor.execInteractive(arguments: args)
            } catch let error as SSHError {
                if case .executionFailed(let exitCode) = error {
                    throw ExitCode(exitCode)
                }
                throw error
            }
        }
    }
}

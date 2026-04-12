import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Shows the IP address of a running VM.
    ///
    /// Resolves the VM's IP by looking up its MAC address in the
    /// host's DHCP lease table and ARP cache. The VM must be running
    /// and have an active network connection.
    struct IP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the IP address of a running VM.",
            discussion: """
                Resolves the VM's IP address by matching its MAC address \
                against the host's DHCP lease database and ARP table.

                The VM must be running with NAT or bridged networking. \
                Isolated-mode VMs have no network interface and cannot \
                be resolved.

                EXAMPLES:
                  spook ip my-vm
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

            guard PIDFile.isRunning(bundleURL: bundleURL) else {
                print("Error: VM '\(name)' is not running. Start it with 'spook start \(name)'.")
                throw ExitCode.failure
            }

            let bundle = try VMBundle.load(from: bundleURL)

            guard let macAddress = bundle.spec.macAddress else {
                print("Error: VM '\(name)' has no configured MAC address.")
                print("The Virtualization framework assigns a random MAC at runtime.")
                print("")
                print("To enable IP resolution, set a stable MAC address:")
                print("  spook set \(name) --mac-address $(uuidgen | sed 's/-//g' | head -c 12 | sed 's/../&:/g;s/:$//' | sed 's/^../02/')")
                throw ExitCode.failure
            }

            let ip = try await IPResolver.resolveIP(macAddress: macAddress)

            if let ip {
                print(ip)
            } else {
                print("Error: Could not resolve IP for VM '\(name)' (MAC: \(macAddress)).")
                print("The VM may still be booting or may not have a network address yet.")
                throw ExitCode.failure
            }
        }
    }
}

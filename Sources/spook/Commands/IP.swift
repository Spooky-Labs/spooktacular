import ArgumentParser
import Foundation

extension Spook {

    /// Shows the IP address of a running VM.
    struct IP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the IP address of a running VM."
        )

        @Argument(help: "Name of the VM.")
        var name: String

        func run() async throws {
            // IP resolution requires a running VM with an active
            // network connection. In the full architecture, the
            // helper daemon tracks IPs via ARP/DHCP/vsock.
            // For now, show the user how to find it.
            print("IP resolution requires a running VM.")
            print("While the VM is running, check the guest's")
            print("System Settings → Network for its IP address.")
            print("")
            print("(Automatic IP resolution via the helper daemon is coming soon.)")
        }
    }
}

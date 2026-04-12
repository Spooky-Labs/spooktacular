import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Stops a running virtual machine.
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a running VM."
        )

        @Argument(help: "Name of the VM to stop.")
        var name: String

        func run() async throws {
            // For now, this is a placeholder — stopping requires
            // a reference to the running VirtualMachine instance,
            // which will be managed by the helper daemon in the
            // full architecture. In the demo, Ctrl+C stops the VM.
            print("To stop a running VM, press Ctrl+C in the terminal where it's running.")
            print("(Full stop command requires the helper daemon, coming soon.)")
        }
    }
}

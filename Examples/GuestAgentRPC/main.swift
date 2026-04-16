import Foundation
import SpookCore
import SpookInfrastructureApple

/// Runs a shell command inside an already-running VM over vsock.
///
/// Usage:
///
///     swift run GuestAgentRPC <vm-name> <command>
///
/// Example:
///
///     swift run GuestAgentRPC runner-01 "uptime"
///
/// This example demonstrates the guest agent client factory —
/// `VirtualMachine.makeGuestAgentClient()` is the supported entry to
/// the vsock host-to-guest channel. No need to import the
/// Virtualization framework or reach into `vzVM.socketDevices`.
@main
struct GuestAgentRPCExample {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: GuestAgentRPC <vm-name> <command> [args...]")
            exit(EXIT_FAILURE)
        }
        let vmName = args[1]
        let command = args.dropFirst(2).joined(separator: " ")

        let bundleURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: ".spooktacular/vms")
            .appending(path: "\(vmName).vm")

        let bundle = try VirtualMachineBundle.load(from: bundleURL)
        let vm = try await MainActor.run { try VirtualMachine(bundle: bundle) }

        guard let client = await vm.makeGuestAgentClient(
            runnerToken: ProcessInfo.processInfo.environment["SPOOK_RUNNER_TOKEN"]
        ) else {
            print("error: VM '\(vmName)' has no VirtIO socket device.")
            exit(EXIT_FAILURE)
        }

        let response = try await client.exec(command)
        FileHandle.standardOutput.write(Data(response.stdout.utf8))
        FileHandle.standardError.write(Data(response.stderr.utf8))
        exit(response.exitCode)
    }
}

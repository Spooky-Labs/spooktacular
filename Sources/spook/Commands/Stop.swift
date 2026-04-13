import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Stops a running virtual machine.
    ///
    /// Reads the PID file from the VM's bundle directory and sends
    /// SIGTERM to the `spook start` process that owns the VM. The
    /// start process handles SIGTERM by gracefully stopping the VM,
    /// cleaning up the PID file, and exiting.
    ///
    /// If the process is not responding, use `--force` to send
    /// SIGKILL instead.
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a running VM.",
            discussion: """
                Sends a termination signal to the process running the \
                VM. The VM is stopped gracefully and its PID file is \
                removed.

                Use --force to send SIGKILL if the VM is unresponsive.

                EXAMPLES:
                  spook stop my-vm
                  spook stop my-vm --force
                """
        )

        @Argument(help: "Name of the VM to stop.")
        var name: String

        @Flag(help: "Send SIGKILL instead of SIGTERM.")
        var force: Bool = false

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            guard let pid = PIDFile.read(from: bundleURL) else {
                print(Style.dim("VM '\(name)' is not running (no PID file found)."))
                return
            }

            guard PIDFile.isProcessAlive(pid) else {
                print(Style.dim("VM '\(name)' is not running (stale PID file, process \(pid) exited)."))
                // Clean up the stale PID file.
                PIDFile.remove(from: bundleURL)
                return
            }

            let signalNumber: Int32 = force ? SIGKILL : SIGTERM
            let signalName = force ? "SIGKILL" : "SIGTERM"

            print(Style.info("Sending \(signalName) to VM '\(name)' (PID \(pid))..."))
            let result = kill(pid, signalNumber)

            if result == 0 {
                print(Style.success("✓ Signal sent. VM '\(name)' is stopping."))

                // If we sent SIGKILL, the process won't clean up its
                // PID file, so we remove it ourselves.
                if force {
                    PIDFile.remove(from: bundleURL)
                }
            } else {
                let errorCode = errno
                print(Style.error("✗ Failed to send signal to PID \(pid): errno \(errorCode)"))
                // Clean up stale PID file if the process no longer exists.
                if errorCode == ESRCH {
                    PIDFile.remove(from: bundleURL)
                    print(Style.dim("Cleaned up stale PID file."))
                }
                throw ExitCode.failure
            }
        }
    }
}

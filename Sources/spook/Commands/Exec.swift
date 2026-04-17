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
            transform: { $0.expandingTilde }
        )
        var key: String = "~/.ssh/id_ed25519"

        @Argument(
            parsing: .captureForPassthrough,
            help: "Command and arguments to execute in the guest."
        )
        var command: [String] = []

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

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

            // Join the user's command tokens into a single string for
            // SSH — SSH protocol transmits the remote command as one
            // string, so we can't avoid joining. But we MUST
            // POSIX-quote each token first; joining raw tokens with
            // spaces invites shell metacharacter injection (`;`,
            // `|`, `$()`, etc.) when any token contains them. Before
            // this guard, `spook exec vm 'whoami; rm -rf /'` would
            // run both commands remotely.
            let commandString = command.map { posixShellEscape($0) }
                                       .joined(separator: " ")

            guard let macAddress = bundle.spec.macAddress else {
                print(Style.error("✗ VM '\(name)' has no configured MAC address for automatic IP resolution."))
                print(Style.dim("  Find the IP manually, then run:"))
                print(Style.dim("  ssh \(user)@<ip-address> \(commandString)"))
                throw ExitCode.failure
            }

            guard let ip = try await IPResolver.resolveIP(macAddress: macAddress) else {
                print(Style.error("✗ Could not resolve IP for VM '\(name)'."))
                print(Style.dim("  The VM may still be booting. Try again in a few seconds."))
                throw ExitCode.failure
            }

            var args = SSHExecutor.sshOptions
            args += ["-i", key, "\(user)@\(ip)", commandString]

            do {
                try SSHExecutor.execInteractive(arguments: args)
            } catch let error as SSHError {
                if case .executionFailed(let exitCode) = error {
                    throw ExitCode(exitCode)
                }
                throw error
            }
        }

        /// Quotes a string for safe use as a single POSIX shell token.
        ///
        /// Wraps in single quotes and escapes any literal single
        /// quotes inside the string by breaking out of the quoting
        /// (`'\''` sequence). Everything between single quotes is
        /// taken literally by the shell — no variable expansion,
        /// no command substitution, no metacharacter interpretation.
        /// This is the standard defense against shell-injection when
        /// a command string has to be transmitted as one blob.
        private func posixShellEscape(_ s: String) -> String {
            return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
    }
}

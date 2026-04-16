import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Interacts with a running VM's guest agent over VirtIO socket.
    ///
    /// The `remote` command family communicates with the `spooktacular-agent`
    /// daemon inside a guest VM via the hypervisor's VirtIO socket
    /// (vsock). Unlike SSH-based commands, these require no network
    /// configuration — the vsock channel is available as soon as the
    /// VM boots and the agent starts.
    ///
    /// Each subcommand connects to the agent, sends a request, and
    /// prints the result.
    struct Remote: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remote",
            abstract: "Interact with a running VM's guest agent.",
            discussion: """
                Requires the Spooktacular guest agent (spooktacular-agent) \
                installed in the VM. Unlike SSH-based commands, these \
                use the VirtIO socket — no network configuration needed.

                EXAMPLES:
                  spook remote health my-vm
                  spook remote exec my-vm -- uname -a
                  spook remote clipboard get my-vm
                  spook remote apps my-vm
                  spook remote ports my-vm
                """,
            subcommands: [
                Exec.self,
                Clipboard.self,
                Apps.self,
                Health.self,
                Ports.self,
            ]
        )
    }
}

// MARK: - Shared Helpers

extension Spook.Remote {

    /// Resolves a VM name to a running VM's VirtIO socket device
    /// and guest agent client.
    ///
    /// This helper encapsulates the common setup for all remote
    /// subcommands:
    /// 1. Resolves the bundle by name.
    /// 2. Verifies the VM is running via its PID file.
    /// 3. Creates a `VirtualMachine` from the bundle.
    /// 4. Extracts the `VZVirtioSocketDevice`.
    /// 5. Returns a `GuestAgentClient`.
    ///
    /// - Parameter name: The VM name.
    /// - Returns: A `GuestAgentClient` connected to the VM's
    ///   socket device.
    /// - Throws: `ExitCode.failure` with styled error output if
    ///   the VM is not found, not running, or has no socket device.
    @MainActor
    static func requireAgent(for name: String) throws -> GuestAgentClient {
        let bundleURL = try requireBundle(for: name)

        guard PIDFile.isRunning(bundleURL: bundleURL) else {
            print(Style.error("✗ VM '\(name)' is not running."))
            print(Style.dim("  Start it with 'spook start \(name)'."))
            throw ExitCode.failure
        }

        let bundle = try VirtualMachineBundle.load(from: bundleURL)
        let vm = try VirtualMachine(bundle: bundle)

        guard let client = vm.makeGuestAgentClient() else {
            print(Style.error("✗ VM '\(name)' has no VirtIO socket device."))
            print(Style.dim(
                "  The VM configuration may be missing the socket device. "
                + "Re-create the VM or check its config."
            ))
            throw ExitCode.failure
        }
        return client
    }
}

// MARK: - Remote.Exec

extension Spook.Remote {

    /// Runs a command inside a running VM via the guest agent.
    ///
    /// Unlike `spook exec` which uses SSH, this command communicates
    /// over the VirtIO socket — no network needed. The command is
    /// run in the guest's default shell and output is printed to
    /// the host terminal.
    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a command inside the guest via the agent.",
            discussion: """
                Runs a shell command inside the guest using the \
                spooktacular-agent. Output (stdout and stderr) is printed to \
                the host terminal.

                Use '--' to separate spook arguments from the guest \
                command.

                EXAMPLES:
                  spook remote exec my-vm -- uname -a
                  spook remote exec my-vm -- sw_vers
                  spook remote exec my-vm -- /bin/bash -c "echo hello"
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(
            parsing: .captureForPassthrough,
            help: "Command and arguments to run in the guest."
        )
        var command: [String] = []

        @MainActor
        func run() async throws {
            guard !command.isEmpty else {
                print(Style.error("✗ No command specified."))
                print(Style.dim(
                    "  Use '--' followed by the command. "
                    + "Example: spook remote exec \(name) -- uname -a"
                ))
                throw ExitCode.failure
            }

            let agent = try Spook.Remote.requireAgent(for: name)
            let commandString = command.joined(separator: " ")

            print(Style.dim("Running via guest agent..."))

            let result = try await agent.exec(commandString)

            if !result.stdout.isEmpty {
                print(result.stdout, terminator: result.stdout.hasSuffix("\n") ? "" : "\n")
            }
            if !result.stderr.isEmpty {
                FileHandle.standardError.write(
                    Data(result.stderr.utf8)
                )
            }
            if result.exitCode != 0 {
                throw ExitCode(result.exitCode)
            }
        }
    }
}

// MARK: - Remote.Clipboard

extension Spook.Remote {

    /// Gets or sets the guest's clipboard via the agent.
    ///
    /// Use `get` to read the guest clipboard and print it to
    /// stdout. Use `set` to write text to the guest clipboard.
    struct Clipboard: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Get or set the guest clipboard.",
            discussion: """
                Reads or writes the guest VM's clipboard via the \
                spooktacular-agent. This uses the VirtIO socket, not the \
                Virtualization framework's clipboard sharing (which \
                is only available for Linux guests).

                EXAMPLES:
                  spook remote clipboard get my-vm
                  spook remote clipboard set my-vm "Hello from host"
                """,
            subcommands: [Get.self, Set.self]
        )
    }
}

extension Spook.Remote.Clipboard {

    /// Reads the guest's clipboard and prints it to stdout.
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the guest clipboard contents."
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @MainActor
        func run() async throws {
            let agent = try Spook.Remote.requireAgent(for: name)
            let text = try await agent.getClipboard()

            if text.isEmpty {
                print(Style.dim("(clipboard is empty)"))
            } else {
                print(text)
            }
        }
    }

    /// Writes text to the guest's clipboard.
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the guest clipboard contents."
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Text to place on the guest clipboard.")
        var text: String

        @MainActor
        func run() async throws {
            let agent = try Spook.Remote.requireAgent(for: name)
            try await agent.setClipboard(text)
            print(Style.success("✓ Clipboard set."))
        }
    }
}

// MARK: - Remote.Apps

extension Spook.Remote {

    /// Lists, launches, or quits applications in the guest.
    ///
    /// With no subcommand, lists all running applications.
    /// Use `launch` or `quit` to control apps by bundle ID.
    struct Apps: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List, launch, or quit guest applications.",
            discussion: """
                Manages running applications inside the guest via the \
                spooktacular-agent. The default action lists all running apps.

                EXAMPLES:
                  spook remote apps my-vm
                  spook remote apps launch my-vm com.apple.Safari
                  spook remote apps quit my-vm com.apple.TextEdit
                """,
            subcommands: [List.self, Launch.self, Quit.self],
            defaultSubcommand: List.self
        )
    }
}

extension Spook.Remote.Apps {

    /// Lists running applications inside the guest.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List running applications in the guest."
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @MainActor
        func run() async throws {
            let agent = try Spook.Remote.requireAgent(for: name)
            let apps = try await agent.listApps()

            if apps.isEmpty {
                print(Style.dim("No running applications."))
                return
            }

            Style.header("Running Applications")
            Style.table(
                headers: ["NAME", "BUNDLE ID", "PID", "ACTIVE"],
                rows: apps.map { app in
                    [
                        app.name,
                        app.bundleID,
                        String(app.pid),
                        app.isActive
                            ? Style.green("yes") : Style.dim("no"),
                    ]
                }
            )
        }
    }

    /// Launches an application by bundle identifier.
    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Launch an application in the guest."
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Bundle identifier of the app (e.g., com.apple.Safari).")
        var bundleID: String

        @MainActor
        func run() async throws {
            let agent = try Spook.Remote.requireAgent(for: name)
            try await agent.launchApp(bundleID: bundleID)
            print(Style.success("✓ Launched '\(bundleID)'."))
        }
    }

    /// Quits an application by bundle identifier.
    struct Quit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Quit an application in the guest."
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Argument(help: "Bundle identifier of the app to quit.")
        var bundleID: String

        @MainActor
        func run() async throws {
            let agent = try Spook.Remote.requireAgent(for: name)
            try await agent.quitApp(bundleID: bundleID)
            print(Style.success("✓ Quit '\(bundleID)'."))
        }
    }
}

// MARK: - Remote.Health

extension Spook.Remote {

    /// Checks whether the guest agent is running and responsive.
    ///
    /// Sends a health-check request to the agent and displays
    /// its version and status. Useful for verifying the agent
    /// is installed and working before running other commands.
    struct Health: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check the guest agent's health.",
            discussion: """
                Connects to the spooktacular-agent inside the VM and checks \
                that it is running and responsive. Displays the agent \
                version and uptime.

                EXAMPLES:
                  spook remote health my-vm
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @MainActor
        func run() async throws {
            let agent = try Spook.Remote.requireAgent(for: name)
            let response = try await agent.health()

            print(Style.success("✓ Guest agent is healthy."))
            Style.field("Status", Style.green(response.status))
            Style.field("Version", response.version)
            Style.field(
                "Uptime",
                formatUptime(response.uptime)
            )
        }

        /// Formats a time interval as a human-readable duration.
        private func formatUptime(_ seconds: TimeInterval) -> String {
            let totalSeconds = Int(seconds)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let secs = totalSeconds % 60

            if hours > 0 {
                return "\(hours)h \(minutes)m \(secs)s"
            } else if minutes > 0 {
                return "\(minutes)m \(secs)s"
            } else {
                return "\(secs)s"
            }
        }
    }
}

// MARK: - Remote.Ports

extension Spook.Remote {

    /// Lists listening TCP ports inside the guest.
    ///
    /// Queries the guest agent for all TCP ports in LISTEN state
    /// and displays them in a table with the owning process name
    /// and PID.
    struct Ports: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List listening TCP ports in the guest.",
            discussion: """
                Queries the spooktacular-agent for all TCP ports in LISTEN \
                state inside the guest. Useful for verifying services \
                are running or finding ports to forward.

                EXAMPLES:
                  spook remote ports my-vm
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @MainActor
        func run() async throws {
            let agent = try Spook.Remote.requireAgent(for: name)
            let ports = try await agent.listeningPorts()

            if ports.isEmpty {
                print(Style.dim("No listening ports."))
                return
            }

            Style.header("Listening Ports")
            Style.table(
                headers: ["PORT", "PROCESS", "PID"],
                rows: ports.map { port in
                    [
                        String(port.port),
                        port.processName,
                        String(port.pid),
                    ]
                }
            )
        }
    }
}

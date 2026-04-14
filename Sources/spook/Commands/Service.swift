import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Manages per-VM LaunchDaemons for headless operation.
    ///
    /// Each virtual machine gets its own LaunchDaemon at
    /// `/Library/LaunchDaemons/com.spooktacular.vm.<name>.plist`
    /// that runs `spook start <name> --headless`.
    ///
    /// Installing and uninstalling require sudo. Status shows
    /// all installed VM daemons and their running state.
    struct Service: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage per-VM LaunchDaemons.",
            discussion: """
                Installs or removes macOS LaunchDaemons that start \
                individual VMs automatically at boot. Each VM gets \
                its own daemon.

                The daemon runs `spook start <name> --headless`.
                Installing and uninstalling require sudo.

                EXAMPLES:
                  sudo spook service install runner-01
                  sudo spook service install runner-02
                  sudo spook service uninstall runner-01
                  spook service status
                """,
            subcommands: [
                Install.self,
                Uninstall.self,
                Status.self,
            ],
            defaultSubcommand: Status.self
        )
    }
}

// MARK: - Install

extension Spook.Service {

    /// Installs a per-VM LaunchDaemon.
    ///
    /// Writes a plist to `/Library/LaunchDaemons/com.spooktacular.vm.<name>.plist`
    /// and loads it via `launchctl`. Requires root privileges (sudo).
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install a LaunchDaemon for a VM.",
            discussion: """
                Writes a per-VM LaunchDaemon plist and loads it with \
                launchctl. The daemon runs `spook start <name> --headless` \
                at boot.

                Requires sudo.

                EXAMPLES:
                  sudo spook service install runner-01
                  sudo spook service install runner-02
                """
        )

        @Argument(help: "Name of the VM to create a daemon for.")
        var name: String

        func run() async throws {
            let executablePath = ProcessInfo.processInfo.arguments[0]
            let plistContent = ServicePlist.generate(
                executablePath: executablePath,
                vmName: name
            )
            let plistPath = ServicePlist.plistPath(for: name)

            Log.provision.info("Installing LaunchDaemon at \(plistPath, privacy: .public)")

            // Write the plist file.
            do {
                try plistContent.write(
                    toFile: plistPath,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                print(Style.error("✗ Failed to write plist to \(plistPath)."))
                print(Style.dim("  This command requires sudo. Try: sudo spook service install \(name)"))
                throw ExitCode.failure
            }

            // Bootstrap the daemon (macOS 13+ replacement for `launchctl load`).
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "system", plistPath]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print(Style.error("✗ Failed to run launchctl bootstrap."))
                throw ExitCode.failure
            }

            if process.terminationStatus == 0 {
                print(Style.success("✓ LaunchDaemon installed and loaded for VM '\(name)'."))
                Style.field("Plist", Style.dim(plistPath))
                Style.field("Log", Style.dim("/var/log/spooktacular.\(name).log"))
                Style.field("Error log", Style.dim("/var/log/spooktacular.\(name).error.log"))
                print("")
                print(Style.dim("The daemon will start '\(name)' automatically at boot."))
                print("To uninstall: \(Style.bold("sudo spook service uninstall \(name)"))")
            } else {
                print(Style.error("✗ launchctl bootstrap failed (exit \(process.terminationStatus))."))
                print(Style.dim("  The plist was written but could not be loaded."))
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - Uninstall

extension Spook.Service {

    /// Uninstalls a per-VM LaunchDaemon.
    ///
    /// Unloads the daemon via `launchctl` and removes the plist
    /// file. Requires root privileges (sudo).
    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Uninstall a VM's LaunchDaemon.",
            discussion: """
                Unloads the daemon with launchctl and removes the \
                plist file for the specified VM.

                Requires sudo.

                EXAMPLES:
                  sudo spook service uninstall runner-01
                """
        )

        @Argument(help: "Name of the VM whose daemon to remove.")
        var name: String

        func run() async throws {
            let plistPath = ServicePlist.plistPath(for: name)

            guard FileManager.default.fileExists(atPath: plistPath) else {
                print(Style.dim("No LaunchDaemon installed for VM '\(name)' (no plist at \(plistPath))."))
                return
            }

            Log.provision.info("Uninstalling LaunchDaemon from \(plistPath, privacy: .public)")

            // Bootout the daemon (macOS 13+ replacement for `launchctl unload`).
            let label = ServicePlist.label(for: name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "system/\(label)"]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print(Style.warning("Could not run launchctl bootout: \(error.localizedDescription)"))
            }

            // Remove the plist file.
            do {
                try FileManager.default.removeItem(atPath: plistPath)
            } catch {
                print(Style.error("✗ Failed to remove plist at \(plistPath)."))
                print(Style.dim("  This command requires sudo. Try: sudo spook service uninstall \(name)"))
                throw ExitCode.failure
            }

            print(Style.success("✓ LaunchDaemon uninstalled for VM '\(name)'."))
            print(Style.dim("The daemon will no longer start '\(name)' at boot."))
        }
    }
}

// MARK: - Status

extension Spook.Service {

    /// Reports the status of all installed VM LaunchDaemons.
    ///
    /// Scans `/Library/LaunchDaemons/` for any
    /// `com.spooktacular.vm.*.plist` files and checks whether
    /// each is currently loaded in `launchctl`.
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show all installed VM daemons and their status.",
            discussion: """
                Lists all installed Spooktacular VM LaunchDaemons \
                and reports whether each is currently running.

                EXAMPLES:
                  spook service status
                """
        )

        func run() async throws {
            let daemonsDir = "/Library/LaunchDaemons"
            let fm = FileManager.default

            // Find all Spooktacular VM plists.
            let prefix = ServicePlist.labelPrefix
            let allFiles = (try? fm.contentsOfDirectory(atPath: daemonsDir)) ?? []
            let vmPlists = allFiles
                .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".plist") }
                .sorted()

            print(Style.bold("Spooktacular VM LaunchDaemons"))
            print("")

            if vmPlists.isEmpty {
                print(Style.dim("No VM daemons installed."))
                print("")
                print("Install one with: \(Style.bold("sudo spook service install <vm-name>"))")
                return
            }

            for plistFile in vmPlists {
                // Extract VM name from filename: com.spooktacular.vm.<name>.plist
                let label = String(plistFile.dropLast(".plist".count))
                let vmName = String(label.dropFirst("\(prefix).".count))

                // `launchctl print` exits 0 when the service is loaded.
                let probe = Process()
                probe.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                probe.arguments = ["print", "system/\(label)"]
                probe.standardOutput = FileHandle.nullDevice
                probe.standardError = FileHandle.nullDevice

                var isRunning = false
                do {
                    try probe.run()
                    probe.waitUntilExit()
                    isRunning = probe.terminationStatus == 0
                } catch {
                    // If launchctl fails, treat as not running.
                }

                let status = isRunning
                    ? Style.green("running")
                    : Style.dim("not running")

                Style.field(vmName, status)
            }
        }
    }
}

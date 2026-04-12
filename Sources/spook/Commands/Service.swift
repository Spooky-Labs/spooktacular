import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Manages the Spooktacular LaunchDaemon for headless operation.
    ///
    /// Installs, uninstalls, or checks the status of a system-wide
    /// LaunchDaemon that starts the Spooktacular daemon at boot.
    /// The daemon runs `spook start --headless` and logs to
    /// `/var/log/spooktacular.log`.
    struct Service: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the Spooktacular LaunchDaemon.",
            discussion: """
                Installs or removes a macOS LaunchDaemon that starts \
                the Spooktacular daemon automatically at boot.

                The daemon runs in headless mode and listens for API \
                requests. Installing and uninstalling require sudo.

                EXAMPLES:
                  sudo spook service install
                  sudo spook service install
                  sudo spook service uninstall
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

// MARK: - Plist Generation

extension Spook.Service {

    /// The LaunchDaemon label used for the plist and `launchctl`.
    static let daemonLabel = "com.spooktacular.daemon"

    /// The file path for the LaunchDaemon plist.
    static let plistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"

    /// Generates the LaunchDaemon plist XML for the given executable
    /// path and bind address.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the `spook` binary.
    ///   - bind: The address and port for the API server to listen on.
    /// - Returns: A UTF-8 XML string suitable for writing to disk.
    static func generatePlist(executablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>list</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>StandardOutPath</key>
            <string>/var/log/spooktacular.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/spooktacular.error.log</string>
        </dict>
        </plist>
        """
    }
}

// MARK: - Install

extension Spook.Service {

    /// Installs the Spooktacular LaunchDaemon.
    ///
    /// Writes a plist to `/Library/LaunchDaemons/` and loads it
    /// via `launchctl`. Requires root privileges (sudo).
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the LaunchDaemon.",
            discussion: """
                Writes a LaunchDaemon plist and loads it with \
                launchctl. The daemon runs `spook start --headless` \
                at boot.

                Requires sudo.

                EXAMPLES:
                  sudo spook service install
                  sudo spook service install
                """
        )

        func run() async throws {
            let executablePath = ProcessInfo.processInfo.arguments[0]
            let plistContent = Spook.Service.generatePlist(
                executablePath: executablePath
            )

            Log.provision.info("Installing LaunchDaemon at \(Spook.Service.plistPath, privacy: .public)")

            // Write the plist file.
            do {
                try plistContent.write(
                    toFile: Spook.Service.plistPath,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                print(Style.error("✗ Failed to write plist to \(Spook.Service.plistPath)."))
                print(Style.dim("  This command requires sudo. Try: sudo spook service install"))
                throw ExitCode.failure
            }

            // Load the daemon.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", Spook.Service.plistPath]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print(Style.error("✗ Failed to run launchctl load."))
                throw ExitCode.failure
            }

            if process.terminationStatus == 0 {
                print(Style.success("✓ LaunchDaemon installed and loaded."))
                Style.field("Plist", Style.dim(Spook.Service.plistPath))
                Style.field("Log", Style.dim("/var/log/spooktacular.log"))
                Style.field("Error log", Style.dim("/var/log/spooktacular.error.log"))
                print("")
                print("The daemon will start automatically at boot.")
                print("To uninstall: \(Style.bold("sudo spook service uninstall"))")
            } else {
                print(Style.error("✗ launchctl load failed (exit \(process.terminationStatus))."))
                print(Style.dim("  The plist was written but could not be loaded."))
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - Uninstall

extension Spook.Service {

    /// Uninstalls the Spooktacular LaunchDaemon.
    ///
    /// Unloads the daemon via `launchctl` and removes the plist
    /// file. Requires root privileges (sudo).
    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Uninstall the LaunchDaemon.",
            discussion: """
                Unloads the daemon with launchctl and removes the \
                plist file.

                Requires sudo.

                EXAMPLES:
                  sudo spook service uninstall
                """
        )

        func run() async throws {
            let plistPath = Spook.Service.plistPath

            guard FileManager.default.fileExists(atPath: plistPath) else {
                print("LaunchDaemon is not installed (no plist at \(plistPath)).")
                return
            }

            Log.provision.info("Uninstalling LaunchDaemon from \(plistPath, privacy: .public)")

            // Unload the daemon.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", plistPath]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print(Style.warning("Could not run launchctl unload: \(error.localizedDescription)"))
            }

            // Remove the plist file.
            do {
                try FileManager.default.removeItem(atPath: plistPath)
            } catch {
                print(Style.error("✗ Failed to remove plist at \(plistPath)."))
                print(Style.dim("  This command requires sudo. Try: sudo spook service uninstall"))
                throw ExitCode.failure
            }

            print(Style.success("✓ LaunchDaemon uninstalled."))
            print("The daemon will no longer start at boot.")
        }
    }
}

// MARK: - Status

extension Spook.Service {

    /// Reports the current status of the Spooktacular LaunchDaemon.
    ///
    /// Checks whether the plist file exists and whether the service
    /// is currently loaded in `launchctl`.
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check LaunchDaemon status.",
            discussion: """
                Reports whether the daemon plist is installed and \
                whether the service is currently loaded.

                EXAMPLES:
                  spook service status
                """
        )

        func run() async throws {
            let plistPath = Spook.Service.plistPath
            let isInstalled = FileManager.default.fileExists(atPath: plistPath)

            // Check if the service is loaded via launchctl list.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["list"]

            let pipe = Pipe()
            process.standardOutput = pipe

            var isLoaded = false
            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    isLoaded = output.contains("spooktacular")
                }
            } catch {
                // If launchctl fails, we just report not loaded.
            }

            print(Style.bold("Spooktacular LaunchDaemon"))
            print("")

            let installStatus = isInstalled
                ? Style.green("installed")
                : Style.dim("not installed")
            Style.field("Plist", installStatus)

            if isInstalled {
                Style.field("Path", Style.dim(plistPath))
            }

            let loadedStatus = isLoaded
                ? Style.green("running")
                : Style.dim("not running")
            Style.field("Status", loadedStatus)
        }
    }
}

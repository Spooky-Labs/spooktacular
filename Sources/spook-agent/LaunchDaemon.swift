/// LaunchDaemon plist generation and installation for `spook-agent`.
///
/// The ``install()`` function writes a LaunchDaemon property list to
/// `/Library/LaunchDaemons/com.spooktacular.agent.plist` and loads it
/// with `launchctl`. The daemon is configured to:
///
/// - Start at boot (`RunAtLoad`).
/// - Restart automatically if the process exits (`KeepAlive`).
/// - Log stdout and stderr to `/var/log/spook-agent.log`.
///
/// ## Usage
///
/// ```bash
/// sudo spook-agent --install-daemon
/// ```
///
/// The binary must already be installed at `/usr/local/bin/spook-agent`
/// before running this command.

import Foundation
import os

/// Helpers for installing the spook-agent LaunchDaemon.
enum LaunchDaemon {

    /// The filesystem path where the plist is installed.
    private static let plistPath = "/Library/LaunchDaemons/com.spooktacular.agent.plist"

    /// The LaunchDaemon label.
    private static let label = "com.spooktacular.agent"

    /// The expected install path for the agent binary.
    private static let agentPath = "/usr/local/bin/spook-agent"

    /// The plist content as an XML property list string.
    ///
    /// Using a string literal avoids pulling in `PropertyListSerialization`
    /// and keeps the output deterministic and human-readable.
    private static let plistContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(label)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(agentPath)</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/var/log/spook-agent.log</string>
        <key>StandardErrorPath</key>
        <string>/var/log/spook-agent.log</string>
    </dict>
    </plist>
    """

    /// Writes the LaunchDaemon plist and loads it via `launchctl`.
    ///
    /// Prints status messages to stdout so the caller can verify
    /// installation succeeded. Exits the process with status 1 on
    /// failure.
    static func install() {
        let log = Logger(subsystem: "com.spooktacular.agent", category: "install")

        // Verify the binary exists where the plist expects it.
        guard FileManager.default.fileExists(atPath: agentPath) else {
            log.error("Agent binary not found at \(agentPath, privacy: .public)")
            print("Error: \(agentPath) not found. Copy the binary there first.")
            exit(1)
        }

        // Write the plist file.
        do {
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            log.error("Failed to write plist: \(error.localizedDescription, privacy: .public)")
            print("Error: Could not write \(plistPath). Are you running as root?")
            exit(1)
        }

        print("Wrote \(plistPath)")

        // Load the daemon.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", plistPath]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("launchctl failed: \(error.localizedDescription, privacy: .public)")
            print("Error: launchctl load failed.")
            exit(1)
        }

        if process.terminationStatus == 0 {
            print("LaunchDaemon loaded. spook-agent will start at boot.")
            log.notice("LaunchDaemon installed and loaded")
        } else {
            print("Warning: launchctl exited with status \(process.terminationStatus).")
            print("The plist was written but may not be loaded. Try: sudo launchctl load \(plistPath)")
        }
    }
}

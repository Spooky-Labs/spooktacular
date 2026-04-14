/// LaunchDaemon and LaunchAgent plist generation and installation for `spook-agent`.
///
/// Two installation modes are provided:
///
/// - **LaunchDaemon** (`--install-daemon`): Installs to
///   `/Library/LaunchDaemons/` and runs as root at boot. This mode
///   cannot access the clipboard or window server.
/// - **LaunchAgent** (`--install-agent`): Installs to
///   `~/Library/LaunchAgents/` and runs in the user's GUI session.
///   This is required for clipboard, app control, and any endpoint
///   that needs the window server.
///
/// ## Usage
///
/// ```bash
/// # LaunchAgent (recommended -- clipboard and app control work):
/// spook-agent --install-agent
///
/// # LaunchDaemon (root, no GUI access):
/// sudo spook-agent --install-daemon
/// ```
///
/// The binary must already be installed at `/usr/local/bin/spook-agent`
/// before running either command.

import Foundation
import os

/// Helpers for installing the spook-agent as a LaunchDaemon or LaunchAgent.
enum LaunchDaemon {

    /// The LaunchDaemon label and plist path.
    private static let daemonLabel = "com.spooktacular.agent"
    private static let daemonPlistPath = "/Library/LaunchDaemons/com.spooktacular.agent.plist"

    /// The LaunchAgent label and plist directory.
    private static let agentLabel = "com.spooktacular.agent"

    /// The expected install path for the agent binary.
    private static let agentBinaryPath = "/usr/local/bin/spook-agent"

    // MARK: - LaunchDaemon

    /// The LaunchDaemon plist content.
    ///
    /// Runs at boot as root with `KeepAlive`. Logs to
    /// `/var/log/spook-agent.log`.
    private static let daemonPlistContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(daemonLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(agentBinaryPath)</string>
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
    /// Exits the process with status 1 on failure.
    static func installDaemon() {
        let log = Logger(subsystem: "com.spooktacular.agent", category: "install")

        guard FileManager.default.fileExists(atPath: agentBinaryPath) else {
            log.error("Agent binary not found at \(agentBinaryPath, privacy: .public)")
            print("Error: \(agentBinaryPath) not found. Copy the binary there first.")
            exit(1)
        }

        do {
            try daemonPlistContent.write(toFile: daemonPlistPath, atomically: true, encoding: .utf8)
        } catch {
            log.error("Failed to write plist: \(error.localizedDescription, privacy: .public)")
            print("Error: Could not write \(daemonPlistPath). Are you running as root?")
            exit(1)
        }

        print("Wrote \(daemonPlistPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "system", daemonPlistPath]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("launchctl failed: \(error.localizedDescription, privacy: .public)")
            print("Error: launchctl bootstrap failed.")
            exit(1)
        }

        if process.terminationStatus == 0 {
            print("LaunchDaemon loaded. spook-agent will start at boot.")
            log.notice("LaunchDaemon installed and loaded")
        } else {
            print("Warning: launchctl exited with status \(process.terminationStatus).")
            print("The plist was written but may not be loaded. Try: sudo launchctl bootstrap system \(daemonPlistPath)")
        }
    }

    // MARK: - LaunchAgent

    /// The LaunchAgent plist content.
    ///
    /// Runs at login in the user's GUI session with `KeepAlive`.
    /// This gives the agent access to the clipboard and window server.
    /// Logs to `~/Library/Logs/spook-agent.log`.
    private static func agentPlistContent(logPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(agentBinaryPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    /// Writes the LaunchAgent plist and loads it via `launchctl bootstrap gui/<uid>`.
    ///
    /// The LaunchAgent installs to `~/Library/LaunchAgents/` so it runs
    /// in the user's GUI session, giving the agent access to the
    /// clipboard, running applications, and the window server.
    ///
    /// Exits the process with status 1 on failure.
    static func installAgent() {
        let log = Logger(subsystem: "com.spooktacular.agent", category: "install")

        guard FileManager.default.fileExists(atPath: agentBinaryPath) else {
            log.error("Agent binary not found at \(agentBinaryPath, privacy: .public)")
            print("Error: \(agentBinaryPath) not found. Copy the binary there first.")
            exit(1)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents")
        let logsDir = home.appendingPathComponent("Library/Logs")
        let plistPath = launchAgentsDir.appendingPathComponent("\(agentLabel).plist").path
        let logPath = logsDir.appendingPathComponent("spook-agent.log").path

        // Ensure directories exist
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            log.error("Failed to create directories: \(error.localizedDescription, privacy: .public)")
            print("Error: Could not create ~/Library/LaunchAgents or ~/Library/Logs.")
            exit(1)
        }

        let plistContent = agentPlistContent(logPath: logPath)

        do {
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            log.error("Failed to write plist: \(error.localizedDescription, privacy: .public)")
            print("Error: Could not write \(plistPath).")
            exit(1)
        }

        print("Wrote \(plistPath)")

        // Load via launchctl bootstrap gui/<uid>
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(uid)", plistPath]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("launchctl failed: \(error.localizedDescription, privacy: .public)")
            print("Error: launchctl bootstrap failed.")
            exit(1)
        }

        if process.terminationStatus == 0 {
            print("LaunchAgent loaded. spook-agent will start at login.")
            log.notice("LaunchAgent installed and loaded for UID \(uid)")
        } else {
            print("Warning: launchctl exited with status \(process.terminationStatus).")
            print("The plist was written but may not be loaded. Try: launchctl bootstrap gui/\(uid) \(plistPath)")
        }
    }
}

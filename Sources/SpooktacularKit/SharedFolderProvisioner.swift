import Foundation
import os

/// Provisions a VM by placing a script in a VirtIO shared folder.
///
/// The script is copied to a staging directory inside the VM bundle
/// that is shared with the guest via VirtIO. A companion
/// LaunchDaemon in the guest watches the shared folder for a
/// `.run-now` trigger file and executes `user-data.sh` when it
/// appears.
///
/// ## How It Works
///
/// 1. The host creates a `shared-provisioning/` directory inside
///    the VM bundle.
/// 2. The user's script is copied to `user-data.sh` in that
///    directory with executable permissions.
/// 3. A zero-byte `.run-now` trigger file is written alongside it.
/// 4. The VM's VirtIO shared folder configuration makes this
///    directory visible at `/Volumes/My Shared Files/` in the guest.
/// 5. The watcher LaunchDaemon (installed via ``watcherInstallScript()``)
///    checks for `.run-now` every 5 seconds. When found, it deletes
///    the trigger and executes `user-data.sh`.
///
/// ## Usage
///
/// ```swift
/// try SharedFolderProvisioner.provision(
///     script: scriptURL,
///     bundle: bundle
/// )
/// ```
///
/// ## Thread Safety
///
/// All methods are synchronous and use only `FileManager`.
/// Call from a background thread if needed to avoid blocking
/// the main thread.
public enum SharedFolderProvisioner {

    /// The LaunchDaemon label used for the shared-folder watcher.
    ///
    /// This identifier is used as the `Label` in the watcher
    /// LaunchDaemon plist and as the plist file name.
    public static let watcherLabel = "com.spooktacular.shared-folder-watcher"

    /// The name of the script file placed in the shared folder.
    public static let scriptFileName = "user-data.sh"

    /// The name of the trigger file that signals the watcher
    /// to execute the script.
    public static let triggerFileName = ".run-now"

    /// The interval, in seconds, at which the watcher daemon
    /// checks for the trigger file.
    public static let watcherInterval = 5

    // MARK: - Staging Directory

    /// Returns the staging directory URL for a given VM bundle.
    ///
    /// The staging directory is `shared-provisioning/` inside the
    /// bundle directory. This directory is shared with the guest
    /// via VirtIO.
    ///
    /// - Parameter bundle: The VM bundle.
    /// - Returns: The file URL of the staging directory.
    public static func stagingDirectory(for bundle: VirtualMachineBundle) -> URL {
        bundle.url.appendingPathComponent("shared-provisioning")
    }

    // MARK: - Provision

    /// Places a script in the shared folder for guest-side execution.
    ///
    /// Creates the staging directory if needed, copies the script
    /// with executable permissions, and writes the trigger file.
    ///
    /// - Parameters:
    ///   - script: The local file URL of the shell script.
    ///   - bundle: The target VM bundle.
    /// - Throws: ``SharedFolderProvisionerError/scriptNotFound(path:)``
    ///   if the script does not exist, or a file system error if
    ///   copying fails.
    public static func provision(
        script: URL,
        bundle: VirtualMachineBundle
    ) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: script.path) else {
            throw SharedFolderProvisionerError.scriptNotFound(path: script.path)
        }

        let stagingDir = stagingDirectory(for: bundle)
        try fileManager.createDirectory(
            at: stagingDir,
            withIntermediateDirectories: true
        )

        let destination = stagingDir.appendingPathComponent(scriptFileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: script, to: destination)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )

        let trigger = stagingDir.appendingPathComponent(triggerFileName)
        try Data().write(to: trigger)

        Log.provision.notice(
            "Script placed in shared folder at \(stagingDir.path, privacy: .public)"
        )
        Log.provision.info(
            "The guest watcher daemon will execute it on next check"
        )
    }

    // MARK: - Watcher Plist

    /// Generates the watcher LaunchDaemon plist XML.
    ///
    /// The plist configures `launchd` to run a shell command every
    /// ``watcherInterval`` seconds that checks for the trigger file
    /// at `/Volumes/My Shared Files/.run-now`. When found, the
    /// trigger is removed and `user-data.sh` is executed.
    ///
    /// - Returns: The plist XML as a string, suitable for writing
    ///   to `/Library/LaunchDaemons/`.
    public static func watcherPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(watcherLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>-c</string>
                <string>if [ -f "/Volumes/My Shared Files/\(triggerFileName)" ]; then rm "/Volumes/My Shared Files/\(triggerFileName)" &amp;&amp; /bin/bash "/Volumes/My Shared Files/\(scriptFileName)" > /var/log/spooktacular-shared-folder.log 2>&amp;1; fi</string>
            </array>
            <key>StartInterval</key>
            <integer>\(watcherInterval)</integer>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }

    // MARK: - Watcher Install Script

    /// Generates a shell script that installs the watcher LaunchDaemon
    /// in the guest.
    ///
    /// The script writes the watcher plist to
    /// `/Library/LaunchDaemons/` and loads it with `launchctl`.
    /// This is intended for injection via ``DiskInjector`` as a
    /// one-time setup step.
    ///
    /// - Returns: The shell script content as a string.
    public static func watcherInstallScript() -> String {
        let plistContent = watcherPlist()
        let plistPath = "/Library/LaunchDaemons/\(watcherLabel).plist"

        return """
        #!/bin/bash
        set -euo pipefail

        # Install the Spooktacular shared-folder watcher daemon.
        cat > '\(plistPath)' << 'PLIST_EOF'
        \(plistContent)
        PLIST_EOF

        chmod 644 '\(plistPath)'
        chown root:wheel '\(plistPath)'

        # Load the daemon if launchctl is available.
        if command -v launchctl &> /dev/null; then
            launchctl load -w '\(plistPath)' 2>/dev/null || true
        fi

        echo "Spooktacular shared-folder watcher installed."
        """
    }
}

// MARK: - Errors

/// An error that occurs during shared-folder provisioning operations.
///
/// Each case provides a specific ``errorDescription`` for display
/// in the CLI, GUI, or logs, and a ``recoverySuggestion`` with
/// actionable guidance for the user.
public enum SharedFolderProvisionerError: Error, Sendable, Equatable, LocalizedError {

    /// The user-data script file was not found.
    ///
    /// - Parameter path: The path that was provided for the script.
    case scriptNotFound(path: String)

    /// The staging directory could not be created.
    ///
    /// - Parameter path: The expected path of the staging directory.
    case stagingDirectoryFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .scriptNotFound(let path):
            "User-data script not found at '\(path)'."
        case .stagingDirectoryFailed(let path):
            "Failed to create staging directory at '\(path)'."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .scriptNotFound:
            "Verify the path to your user-data script exists and is readable."
        case .stagingDirectoryFailed:
            "Ensure the VM bundle directory is writable and not on a read-only volume."
        }
    }
}

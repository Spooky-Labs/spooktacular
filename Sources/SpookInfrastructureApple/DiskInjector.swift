import Foundation
import SpookCore
import SpookApplication
import os

/// Injects a user-data script into a VM's guest disk as a macOS LaunchDaemon.
///
/// Before the VM boots, `DiskInjector` mounts the guest disk image on the host,
/// writes a standard macOS LaunchDaemon plist and the user's script to the data
/// volume, then unmounts. When the VM boots, `launchd` picks up the daemon and
/// executes the script automatically — no SSH, no agent, no network required.
///
/// This uses Apple's `hdiutil` (ships with macOS) to attach APFS disk images
/// and writes only to the data volume (never the Signed System Volume).
///
/// ## Usage
///
/// ```swift
/// let scriptURL = URL(fileURLWithPath: "/path/to/setup.sh")
/// let bundle = try VirtualMachineBundle.load(from: bundleURL)
/// try DiskInjector.inject(script: scriptURL, into: bundle)
/// ```
///
/// ## How It Works
///
/// 1. Attaches the guest's `disk.img` using `hdiutil` without mounting
///    (to discover the device node).
/// 2. Finds and mounts the APFS data volume from the attached disk.
/// 3. Writes the user's script to `/usr/local/bin/spooktacular-user-data.sh`
///    on the data volume.
/// 4. Writes a LaunchDaemon plist to `/Library/LaunchDaemons/` that tells
///    `launchd` to run the script at boot.
/// 5. Detaches the disk image so the VM can boot cleanly.
///
/// ## Thread Safety
///
/// All methods are synchronous and use `Process` to invoke `hdiutil`.
/// Call from a background thread if needed to avoid blocking the main thread.
public enum DiskInjector {

    // MARK: - Public API

    /// The LaunchDaemon label used for injected user-data scripts.
    ///
    /// This identifier is used as the `Label` in the LaunchDaemon
    /// plist and as the plist file name. It must be unique within
    /// the guest's `/Library/LaunchDaemons/` directory.
    public static let daemonLabel = "com.spooktacular.user-data"

    /// The path where the user-data script is installed inside the guest.
    ///
    /// This is relative to the data volume root, so the full path
    /// on the mounted volume is `<mountpoint>/usr/local/bin/spooktacular-user-data.sh`.
    public static let guestScriptPath = "/usr/local/bin/spooktacular-user-data.sh"

    /// Injects a script into the VM's disk image as a LaunchDaemon.
    ///
    /// The VM must be stopped. The disk image is mounted temporarily,
    /// the script and a LaunchDaemon plist are written, then the disk
    /// is unmounted.
    ///
    /// - Parameters:
    ///   - scriptURL: Path to the shell script to inject.
    ///   - bundle: The target VM bundle (must contain `disk.img`).
    /// - Throws: ``DiskInjectorError`` if mounting, writing, or unmounting fails.
    public static func inject(script scriptURL: URL, into bundle: VirtualMachineBundle) throws {
        let diskPath = bundle.url.appendingPathComponent(VirtualMachineBundle.diskImageFileName).path

        guard FileManager.default.fileExists(atPath: diskPath) else {
            throw DiskInjectorError.diskImageNotFound(path: diskPath)
        }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw DiskInjectorError.scriptNotFound(path: scriptURL.path)
        }

        Log.provision.info("Mounting guest disk for injection: \(diskPath, privacy: .public)")

        let attachOutput = try runProcess("/usr/bin/hdiutil", arguments: [
            "attach", diskPath, "-nomount", "-plist",
        ])

        guard let devicePath = parseDeviceFromPlist(attachOutput) else {
            throw DiskInjectorError.mountFailed(
                reason: "Could not parse device path from hdiutil output"
            )
        }

        defer {
            _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", devicePath, "-force"])
            Log.provision.debug("Detached disk image")
        }

        let volumePath = try mountDataVolume(devicePath: devicePath)

        let scriptDestination = "\(volumePath)\(guestScriptPath)"
        let scriptDirectory = (scriptDestination as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: scriptDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(atPath: scriptURL.path, toPath: scriptDestination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptDestination
        )

        let plistPath = "\(volumePath)/Library/LaunchDaemons/\(daemonLabel).plist"
        let plistDirectory = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: plistDirectory,
            withIntermediateDirectories: true
        )
        try generateLaunchDaemonPlist().write(toFile: plistPath, atomically: true, encoding: .utf8)

        Log.provision.notice("Injected user-data script and LaunchDaemon into guest disk")
    }

    // MARK: - LaunchDaemon Plist Generation

    /// Generates the LaunchDaemon plist XML that runs the injected script at boot.
    ///
    /// The plist configures `launchd` to:
    /// - Run `/bin/bash /usr/local/bin/spooktacular-user-data.sh` at load time
    /// - Log stdout to `/var/log/spooktacular-user-data.log`
    /// - Log stderr to `/var/log/spooktacular-user-data.error.log`
    ///
    /// - Returns: The plist XML as a string.
    public static func generateLaunchDaemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(guestScriptPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/var/log/spooktacular-user-data.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/spooktacular-user-data.error.log</string>
        </dict>
        </plist>
        """
    }

    // MARK: - Internal Helpers

    /// Runs a process and captures its standard output.
    ///
    /// Delegates to ``ProcessRunner/run(_:arguments:)`` and maps
    /// any ``ProcessRunnerError`` to ``DiskInjectorError/processFailed(command:exitCode:)``
    /// so the public error contract is preserved.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the executable.
    ///   - arguments: Command-line arguments.
    /// - Returns: The captured standard output as a string.
    /// - Throws: ``DiskInjectorError/processFailed(command:exitCode:)``
    ///   if the process exits with a non-zero status.
    @discardableResult
    static func runProcess(
        _ path: String,
        arguments: [String]
    ) throws -> String {
        do {
            return try ProcessRunner.run(path, arguments: arguments)
        } catch let error as ProcessRunnerError {
            switch error {
            case .processFailed(let command, let exitCode):
                throw DiskInjectorError.processFailed(
                    command: command,
                    exitCode: exitCode
                )
            }
        }
    }

    /// Parses the whole-disk device path from `hdiutil attach -plist` output.
    ///
    /// The plist contains a `system-entities` array. The entry whose
    /// `content-hint` is `GUID_partition_scheme` (or the first entry
    /// with a `dev-entry`) gives us the whole-disk device node
    /// (e.g. `/dev/disk4`).
    ///
    /// - Parameter plistOutput: The XML plist string from `hdiutil`.
    /// - Returns: The device path, or `nil` if parsing failed.
    static func parseDeviceFromPlist(_ plistOutput: String) -> String? {
        guard let data = plistOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            return nil
        }

        if let guid = entities.first(where: { ($0["content-hint"] as? String) == "GUID_partition_scheme" }),
           let devEntry = guid["dev-entry"] as? String {
            return devEntry
        }

        return entities.first?["dev-entry"] as? String
    }

    /// Mounts the APFS data volume from an attached disk device.
    ///
    /// Uses `diskutil` to list APFS volumes on the device and mounts
    /// the one whose role is "Data" (the writable data volume, as
    /// opposed to the Signed System Volume).
    ///
    /// - Parameter devicePath: The whole-disk device node (e.g. `/dev/disk4`).
    /// - Returns: The mount point path of the data volume.
    /// - Throws: ``DiskInjectorError/mountFailed(reason:)`` if no
    ///   data volume is found or mounting fails.
    static func mountDataVolume(devicePath: String) throws -> String {
        // List APFS volumes scoped to our device to avoid matching unrelated containers.
        let listOutput = try runProcess("/usr/sbin/diskutil", arguments: [
            "apfs", "list", "-plist", devicePath,
        ])

        guard let data = listOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]]
        else {
            throw DiskInjectorError.mountFailed(
                reason: "Could not parse APFS container list"
            )
        }

        let devicePrefix = devicePath.hasSuffix("/") ? devicePath : devicePath + "/"
        for container in containers {
            guard let designatedPhysicalStore = container["DesignatedPhysicalStore"] as? String,
                  designatedPhysicalStore == devicePath
                      || designatedPhysicalStore.hasPrefix(devicePrefix)
                      || devicePath.hasPrefix(
                          (designatedPhysicalStore as NSString).deletingLastPathComponent + "/"
                      )
            else { continue }

            guard let volumes = container["Volumes"] as? [[String: Any]] else { continue }

            for volume in volumes {
                guard let roles = volume["Roles"] as? [String],
                      roles.contains("Data"),
                      let deviceIdentifier = volume["DeviceIdentifier"] as? String
                else { continue }

                let mountOutput = try runProcess("/usr/sbin/diskutil", arguments: [
                    "mount", deviceIdentifier,
                ])

                let infoOutput = try runProcess("/usr/sbin/diskutil", arguments: [
                    "info", "-plist", deviceIdentifier,
                ])

                if let infoData = infoOutput.data(using: .utf8),
                   let infoPlist = try? PropertyListSerialization.propertyList(
                       from: infoData, format: nil
                   ) as? [String: Any],
                   let mountPoint = infoPlist["MountPoint"] as? String,
                   !mountPoint.isEmpty
                {
                    Log.provision.info(
                        "Mounted data volume at \(mountPoint, privacy: .public)"
                    )
                    return mountPoint
                }

                if let range = mountOutput.range(of: " on ") {
                    let rest = mountOutput[range.upperBound...]
                    let mountPoint = String(rest.prefix(while: { $0 != "\n" }))
                        .trimmingCharacters(in: .whitespaces)
                    if !mountPoint.isEmpty {
                        return mountPoint
                    }
                }

                throw DiskInjectorError.mountFailed(
                    reason: "Mounted volume \(deviceIdentifier) but could not determine mount point"
                )
            }
        }

        throw DiskInjectorError.mountFailed(
            reason: "No APFS data volume found on device \(devicePath)"
        )
    }
}

// MARK: - Errors

/// An error that occurs during disk injection operations.
///
/// Each case provides a specific ``errorDescription`` for display
/// in the CLI, GUI, or logs, and a ``recoverySuggestion`` with
/// actionable guidance for the user.
public enum DiskInjectorError: Error, Sendable, Equatable, LocalizedError {

    /// The guest disk image was not found in the VM bundle.
    ///
    /// - Parameter path: The expected path to `disk.img`.
    case diskImageNotFound(path: String)

    /// The user-data script file was not found.
    ///
    /// - Parameter path: The path that was provided for the script.
    case scriptNotFound(path: String)

    /// Mounting the guest disk image failed.
    ///
    /// - Parameter reason: A description of what went wrong.
    case mountFailed(reason: String)

    /// A subprocess exited with a non-zero status.
    ///
    /// - Parameters:
    ///   - command: The command that was executed.
    ///   - exitCode: The process exit code.
    case processFailed(command: String, exitCode: Int32)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .diskImageNotFound(let path):
            "Disk image not found at '\(path)'."
        case .scriptNotFound(let path):
            "User-data script not found at '\(path)'."
        case .mountFailed(let reason):
            "Failed to mount guest disk: \(reason)."
        case .processFailed(let command, let exitCode):
            "Command failed with exit code \(exitCode): \(command)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .diskImageNotFound:
            "Ensure the VM bundle contains a 'disk.img' file. "
            + "The bundle may be corrupted — try deleting and recreating the VM."
        case .scriptNotFound:
            "Verify the path to your user-data script exists and is readable."
        case .mountFailed:
            "Ensure the VM is stopped and no other process has the disk image mounted. "
            + "Try running 'hdiutil info' to check for stuck mounts."
        case .processFailed:
            "Check that macOS system tools (hdiutil, diskutil) are available. "
            + "This operation requires running on a Mac with full disk access."
        }
    }
}

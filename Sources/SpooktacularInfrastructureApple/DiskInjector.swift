import Foundation
import SpooktacularCore
import SpooktacularApplication
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
/// let scriptURL = URL(filePath: "/path/to/setup.sh")
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

    /// Installs `Spooktacular Guest Tools.app` into a stopped
    /// VM's `/Applications/` directory.
    ///
    /// The Apple-native equivalent of what the legacy
    /// script-based ``inject(script:into:)`` path does for the
    /// `spooktacular-agent` Mach-O: mount the guest's APFS
    /// data volume, `/usr/bin/ditto` the bundle onto it
    /// (ditto preserves `.app` metadata — resource forks,
    /// xattrs, symlinks, Frameworks/ directory structure —
    /// natively, where a `tar` or shell-level `cp -R` would
    /// require flag juggling), unmount.
    ///
    /// No bash script runs on the guest; no base64 encoding
    /// step; no tarball round-trip. By the time the VM boots
    /// the app is just *there* in `/Applications/`, signed
    /// exactly as it shipped from the host.
    ///
    /// Launch-at-login is owned by the Guest Tools app
    /// itself (via `SMAppService.mainApp` from its menu-bar
    /// UI), not by the host installer — so this function
    /// never writes to `/Library/LaunchAgents/`, never asks
    /// the user for their admin password, and never drops
    /// to `osascript`. A CI-runner VM created with
    /// ``GuestToolsInstallMode/disabled`` skips this
    /// function entirely; a VDI VM created with
    /// ``GuestToolsInstallMode/installed`` gets the `.app`
    /// in `/Applications/`, the user opens it once, and
    /// flips the toggle.
    ///
    /// - Parameters:
    ///   - appBundle: Path to the host-side `.app` bundle.
    ///     Typically resolved via
    ///     ``AppBundleBootstrapTemplate/locateGuestToolsBundle()``.
    ///   - bundle: The target VM bundle (must contain
    ///     `disk.img`; VM must be stopped).
    /// - Throws: ``DiskInjectorError`` if mounting, copying,
    ///   or unmounting fails.
    public static func installGuestTools(
        appBundle appBundleURL: URL,
        into bundle: VirtualMachineBundle
    ) throws {
        let diskPath = bundle.url
            .appendingPathComponent(VirtualMachineBundle.diskImageFileName)
            .path

        guard FileManager.default.fileExists(atPath: diskPath) else {
            throw DiskInjectorError.diskImageNotFound(path: diskPath)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appBundleURL.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw DiskInjectorError.scriptNotFound(path: appBundleURL.path)
        }

        Log.provision.info(
            "Installing guest tools into VM disk: \(diskPath, privacy: .public)"
        )

        let attachOutput = try runProcess("/usr/sbin/diskutil", arguments: [
            "image", "attach", "--nomount", "--plist", diskPath,
        ])
        guard let devicePath = parseDeviceFromPlist(attachOutput) else {
            throw DiskInjectorError.mountFailed(
                reason: "Could not parse device path from diskutil image attach output"
            )
        }
        defer {
            _ = try? runProcess(
                "/usr/bin/hdiutil",
                arguments: ["detach", devicePath, "-force"]
            )
            Log.provision.debug("Detached disk image")
        }

        let volumePath = try ensureDataVolume(devicePath: devicePath)

        // 1. ditto the .app into /Applications on the guest.
        //    Apple's `ditto` with no flags is the correct
        //    primitive here — it preserves every macOS-specific
        //    bundle attribute (xattrs, symlinks, resource
        //    forks, HFS+ compression markers), replaces an
        //    existing bundle atomically, and is what Xcode
        //    itself uses when installing apps during
        //    development. No `rm -rf` before, no post-install
        //    `xattr -rd` workaround.
        let applicationsDir = "\(volumePath)/Applications"
        try FileManager.default.createDirectory(
            atPath: applicationsDir,
            withIntermediateDirectories: true
        )
        let destinationApp = "\(applicationsDir)/\(appBundleURL.lastPathComponent)"
        try runProcess("/usr/bin/ditto", arguments: [
            appBundleURL.path,
            destinationApp,
        ])

        Log.provision.notice(
            "Installed guest tools on guest data volume (destination=\(destinationApp, privacy: .public))"
        )
    }

    /// Writes a user-data script to the VM bundle's provisioning
    /// share as `first-boot.sh`. The Guest Tools LaunchDaemon
    /// inside the guest picks it up on its next boot, runs it
    /// as root, archives the body, and removes the trigger so
    /// subsequent boots no-op.
    ///
    /// Replaces any previously-injected script — a user who
    /// injects twice before the next boot gets the second one.
    /// Previous run logs (`first-boot.stdout.log`, `.stderr.log`,
    /// `.exit-code`) are left alone; the UI surfaces them as
    /// "last run" while the pending script waits.
    ///
    /// - Parameters:
    ///   - scriptURL: Path to the shell script to inject.
    ///   - bundle: The target VM bundle.
    /// - Throws: ``DiskInjectorError`` on I/O failure.
    public static func inject(script scriptURL: URL, into bundle: VirtualMachineBundle) throws {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw DiskInjectorError.scriptNotFound(path: scriptURL.path)
        }

        let fm = FileManager.default
        try fm.createDirectory(
            at: bundle.provisionDirectoryURL,
            withIntermediateDirectories: true
        )
        let destination = bundle.provisionScriptURL
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: scriptURL, to: destination)
        Log.provision.notice(
            "Wrote first-boot script to \(destination.path, privacy: .public) — runs on next VM boot once Guest Tools provisioner is enabled"
        )
    }

    /// Writes raw script bytes to the VM bundle's provisioning
    /// share as `first-boot.sh`. Functionally identical to
    /// ``inject(script:into:)`` but takes the script content
    /// directly — useful when the bytes are generated rather
    /// than read from a file (e.g. ``MDMEnrollmentBootstrap``).
    public static func inject(scriptBytes: Data, into bundle: VirtualMachineBundle) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: bundle.provisionDirectoryURL,
            withIntermediateDirectories: true
        )
        let destination = bundle.provisionScriptURL
        try? fm.removeItem(at: destination)
        try scriptBytes.write(to: destination, options: .atomic)
        // Make the script executable. The `mount_virtiofs` host
        // → guest mapping doesn't preserve POSIX modes
        // identically, but the guest-side runner shells out via
        // `/bin/bash <path>` rather than relying on +x, so
        // setting it here is for parity + Finder visibility.
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
        Log.provision.notice(
            "Wrote \(scriptBytes.count) bytes to \(destination.path, privacy: .public)"
        )
    }

    /// Renders an MDM enrollment bootstrap into the bundle's
    /// `first-boot.sh`. Requires the guest to have already
    /// installed `Spooktacular Provisioner.pkg` (which
    /// installs the LaunchDaemon that runs `first-boot.sh` at
    /// boot). After this call:
    ///
    /// 1. Next VM boot triggers the provisioner runner →
    ///    `first-boot.sh`.
    /// 2. `first-boot.sh` (generated by
    ///    ``MDMEnrollmentBootstrap``) drops the
    ///    `.mobileconfig` to `/var/db/spooktacular/` and
    ///    invokes `profiles install`.
    /// 3. `mdmclient` enrolls against the host's embedded MDM
    ///    server.
    /// 4. After enrollment, host pushes commands directly via
    ///    ``MDMUserDataDispatcher`` — no further bootstrap
    ///    runs needed.
    public static func injectMDMEnrollment(
        bootstrap: MDMEnrollmentBootstrap,
        into bundle: VirtualMachineBundle
    ) throws {
        let scriptBytes = try bootstrap.script()
        try inject(scriptBytes: scriptBytes, into: bundle)
        Log.provision.notice(
            "Injected MDM enrollment bootstrap targeting \(bootstrap.profile.serverURL.absoluteString, privacy: .public) into VM \(bundle.id.uuidString, privacy: .public)"
        )
    }

    // MARK: - LaunchDaemon Plist Generation

    /// Generates the LaunchDaemon plist XML that runs the injected script at boot.
    ///
    /// The plist configures `launchd` to:
    /// - Run `/bin/bash /usr/local/bin/spooktacular-user-data.sh` at load time
    /// - Log stdout to `/var/log/spooktacular-user-data.log`
    /// - Log stderr to `/var/log/spooktacular-user-data.error.log`
    ///
    /// Values are XML-entity-escaped before interpolation so that
    /// a future change to ``daemonLabel`` or ``guestScriptPath``
    /// containing `&`, `<`, `>`, `'`, or `"` cannot produce a plist
    /// `launchd` refuses to parse.
    ///
    /// See Apple's [PropertyListSerialization docs](https://developer.apple.com/documentation/foundation/propertylistserialization)
    /// for the generic plist format. We emit the XML shape directly
    /// because `PropertyListSerialization` writes an OS-specific
    /// binary format by default and emits byte-accurate XML only
    /// with additional work — the hand-written template is simpler
    /// to audit.
    ///
    /// - Returns: The plist XML as a string.
    public static func generateLaunchDaemonPlist() -> String {
        let label = Self.xmlEscape(daemonLabel)
        let scriptPath = Self.xmlEscape(guestScriptPath)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(scriptPath)</string>
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

    /// Escapes the five XML predefined entities (`&`, `<`, `>`, `'`,
    /// `"`) so a string can be safely interpolated between
    /// `<string>` tags in the LaunchDaemon plist template.
    ///
    /// Ordering matters — ampersand must be escaped first, otherwise
    /// it would re-escape the entities we just wrote.
    static func xmlEscape(_ raw: String) -> String {
        var result = raw.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
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
            case .processFailed(let command, _, let stderr, let exitCode):
                throw DiskInjectorError.processFailed(
                    command: command,
                    stderr: stderr,
                    exitCode: exitCode
                )
            }
        }
    }

    /// Parses the whole-disk device path from the attach-plist
    /// produced by `diskutil image attach --plist`.
    ///
    /// The plist contains a `system-entities` array. The entry whose
    /// `content-hint` is `GUID_partition_scheme` (or the first entry
    /// with a `dev-entry`) gives us the whole-disk device node.
    ///
    /// Normalization: `diskutil image attach` returns bare
    /// identifiers ("disk25") whereas `hdiutil attach` returned
    /// fully-qualified paths ("/dev/disk25"). We return the
    /// fully-qualified form unconditionally so downstream code
    /// (`mountDataVolume`, the detach path) has a single contract.
    ///
    /// - Parameter plistOutput: The XML plist string.
    /// - Returns: The device path prefixed with `/dev/`, or `nil` if
    ///   parsing failed.
    static func parseDeviceFromPlist(_ plistOutput: String) -> String? {
        guard let data = plistOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            return nil
        }

        let rawEntry: String?
        if let guid = entities.first(where: { ($0["content-hint"] as? String) == "GUID_partition_scheme" }) {
            rawEntry = guid["dev-entry"] as? String
        } else {
            rawEntry = entities.first?["dev-entry"] as? String
        }

        guard let entry = rawEntry else { return nil }
        // Normalize bare "disk25" → "/dev/disk25".
        return entry.hasPrefix("/dev/") ? entry : "/dev/\(entry)"
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
    /// Calls `mountDataVolume` and — if no Data-role APFS
    /// volume exists on the attached disk — eagerly creates
    /// one via `diskutil apfs addVolume` and retries.
    ///
    /// Freshly-installed macOS guests that have never booted
    /// have a partition layout with System / Preboot / Recovery
    /// / Update volumes but no Data volume — APFS creates the
    /// Data volume lazily at first boot. Without it, there's
    /// nowhere to write a LaunchDaemon plist (System is sealed
    /// and read-only; Preboot is SSV-protected).
    ///
    /// The fix: spawn the Data volume ourselves. `diskutil apfs
    /// addVolume <container> APFS Data -role D` produces the
    /// same volume the guest's first-boot would have produced,
    /// and the subsequent guest boot adopts it as its writable
    /// data volume.
    static func ensureDataVolume(devicePath: String) throws -> String {
        do {
            return try mountDataVolume(devicePath: devicePath)
        } catch DiskInjectorError.mountFailed {
            Log.provision.notice(
                "No Data volume on \(devicePath, privacy: .public) — creating one via diskutil apfs addVolume"
            )
        }
        // Find the APFS container whose physical store is on
        // our attached disk, then add a Data-role volume to it.
        let listOutput = try runProcess("/usr/sbin/diskutil", arguments: [
            "apfs", "list", "-plist",
        ])
        guard let data = listOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]]
        else {
            throw DiskInjectorError.mountFailed(reason: "Could not parse APFS container list while ensuring Data volume")
        }
        let whole = (devicePath as NSString).lastPathComponent
        // Prefer the container with a System-role volume — that's
        // the main macOS install container, not Recovery or ISC.
        var targetContainer: String?
        for container in containers {
            let store = (container["DesignatedPhysicalStore"] as? String ?? "")
            guard (store as NSString).lastPathComponent.hasPrefix(whole) else { continue }
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            let hasSystem = volumes.contains {
                ($0["Roles"] as? [String] ?? []).contains("System")
            }
            if hasSystem, let containerRef = container["ContainerReference"] as? String {
                targetContainer = containerRef
                break
            }
        }
        guard let container = targetContainer else {
            throw DiskInjectorError.mountFailed(reason: "Could not locate the macOS System container on \(devicePath) — disk may be uninstalled or corrupt")
        }
        _ = try runProcess("/usr/sbin/diskutil", arguments: [
            "apfs", "addVolume", container, "APFS", "Data", "-role", "D",
        ])
        // Retry — the new volume shows up in the next list.
        return try mountDataVolume(devicePath: devicePath)
    }

    static func mountDataVolume(devicePath: String) throws -> String {
        // Enumerate every APFS container on the system, then
        // filter to the one whose `DesignatedPhysicalStore`
        // lives on the disk image we just attached.
        //
        // Important: we CANNOT pass `devicePath` (e.g., `/dev/disk25`)
        // to `diskutil apfs list -plist <device>`. That form expects
        // an APFS-container device — a synthesized `diskN` backed by
        // a container — NOT the whole-disk GUID-partition-scheme
        // node that `hdiutil attach` returns, and not the raw
        // physical-store partition (`/dev/disk25s2`). Passing either
        // of those triggers `disk25 is not an APFS Container`, which
        // surfaces to callers as a cryptic "Could not parse APFS
        // container list" in the old code path. Listing everything
        // and filtering locally is the Apple-sanctioned pattern —
        // it's what `diskutil apfs list` without args does by
        // design.
        let listOutput = try runProcess("/usr/sbin/diskutil", arguments: [
            "apfs", "list", "-plist",
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

        // `devicePath` looks like `/dev/disk25` (whole-disk
        // GUID-partition-scheme node). `DesignatedPhysicalStore`
        // values come back as bare identifiers like `disk25s2`
        // (partition of the whole disk). Normalize by extracting
        // the whole-disk identifier ("disk25") so we can match
        // any of its partitions regardless of `/dev/` prefix.
        let wholeDiskIdentifier = (devicePath as NSString).lastPathComponent
        for container in containers {
            guard let designatedPhysicalStore = container["DesignatedPhysicalStore"] as? String
            else { continue }
            // Accept either the bare form (`disk25s2`) or the
            // fully-qualified form (`/dev/disk25s2`) as long as
            // the partition belongs to our whole-disk device.
            let bareStore = (designatedPhysicalStore as NSString).lastPathComponent
            guard bareStore.hasPrefix(wholeDiskIdentifier) else { continue }

            guard let volumes = container["Volumes"] as? [[String: Any]] else { continue }

            for volume in volumes {
                guard let roles = volume["Roles"] as? [String],
                      roles.contains("Data"),
                      let deviceIdentifier = volume["DeviceIdentifier"] as? String
                else { continue }

                // If the Data volume is FileVault-encrypted
                // (the macOS default once Setup Assistant
                // completes), `diskutil mount` bails with
                // "This is an encrypted and locked APFS
                // Volume". The raw error message is accurate
                // but not actionable — translate it into a
                // typed error the GUI can explain clearly.
                let mountOutput: String
                do {
                    mountOutput = try runProcess("/usr/sbin/diskutil", arguments: [
                        "mount", deviceIdentifier,
                    ])
                } catch let DiskInjectorError.processFailed(_, stderr, _)
                    where stderr.contains("encrypted and locked APFS Volume") {
                    throw DiskInjectorError.guestVolumeEncrypted
                }

                let infoOutput = try runProcess("/usr/sbin/diskutil", arguments: [
                    "info", "-plist", deviceIdentifier,
                ])

                if let infoData = infoOutput.data(using: .utf8),
                   let infoPlist = try? PropertyListSerialization.propertyList(
                       from: infoData, format: nil
                   ) as? [String: Any],
                   let mountPoint = infoPlist["MountPoint"] as? String,
                   !mountPoint.isEmpty {
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

    // Host-side user-data delivery writes a single
    // `first-boot.sh` to the bundle's `provision/` share.
    // The guest's Guest Tools LaunchDaemon mounts that share
    // via `mount_virtiofs` on boot and runs the script once.
    // See `ProvisionerInstaller` in `SpooktacularGuestTools`
    // and `applyProvisioning` in `VirtualMachineConfiguration`.
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
    ///   - stderr: Captured stderr output for diagnostic context.
    ///   - exitCode: The process exit code.
    case processFailed(command: String, stderr: String, exitCode: Int32)

    /// Running the privileged chown step failed. The user
    /// either declined the admin-auth prompt, or the
    /// underlying `chown` exited non-zero.
    ///
    /// - Parameter reason: Human-readable description,
    ///   already lightly cleaned of shell prefixes.
    case chownFailed(reason: String)

    /// The guest's APFS Data volume is FileVault-encrypted
    /// and locked. macOS enables FileVault by default during
    /// Setup Assistant, so any attempt to inject a
    /// LaunchDaemon into a guest that has already finished
    /// first-boot hits this path. The mount call surfaces
    /// `"This is an encrypted and locked APFS Volume"` —
    /// accurate but not actionable. We translate it into a
    /// typed case with a clear recovery suggestion.
    case guestVolumeEncrypted

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .diskImageNotFound(let path):
            return "Disk image not found at '\(path)'."
        case .scriptNotFound(let path):
            return "User-data script not found at '\(path)'."
        case .mountFailed(let reason):
            return "Failed to mount guest disk: \(reason)."
        case .processFailed(let command, let stderr, let exitCode):
            let snippet = stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(512)
            if snippet.isEmpty {
                return "Command failed with exit code \(exitCode): \(command)."
            }
            return "Command failed with exit code \(exitCode): \(command). stderr: \(snippet)"
        case .chownFailed(let reason):
            return "Couldn't set root ownership on the guest LaunchDaemon: \(reason)"
        case .guestVolumeEncrypted:
            return "The guest's Data volume is locked by FileVault. Spooktacular Guest Tools can only be installed before the guest's Setup Assistant finishes — once a user account exists, macOS encrypts the volume with a key the host doesn't hold, so disk-injection can no longer reach the guest filesystem."
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
        case .chownFailed:
            "Approve the admin-password prompt when re-running "
            + "'Install Guest Agent'. Apple's launchd silently ignores "
            + "LaunchDaemon plists that aren't owned by root:wheel, and the "
            + "kernel only honours that ownership when set by a privileged "
            + "process on the host."
        case .guestVolumeEncrypted:
            "Delete this VM and create a new one with Guest Tools enabled in "
            + "the create sheet — the tools bundle is injected before first boot, "
            + "before macOS encrypts the Data volume. Retroactive install on a "
            + "set-up VM isn't possible without the FileVault recovery key, "
            + "which the host never sees."
        }
    }
}

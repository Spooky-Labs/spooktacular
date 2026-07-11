import Foundation
import SpooktacularCore

/// Generates user-data scripts for remote desktop (Screen Sharing) VMs.
///
/// When `spook create` is invoked with `--remote-desktop`, this
/// template generates a shell script that:
///
/// 1. Enables Screen Sharing (VNC) via Apple Remote Desktop's
///    `kickstart` tool
/// 2. Enables Remote Login (SSH) via `systemsetup`
///
/// The generated script is written to a temporary file and used
/// as the VM's user-data script, following the same provisioning
/// pipeline as any other user-data.
///
/// ## Usage
///
/// ```swift
/// let url = try RemoteDesktopTemplate.generate()
/// // Use `url` as the --user-data script for the VM.
/// ```
///
/// ## Security
///
/// The script enables full VNC access with all privileges. In
/// production environments, restrict access using the `-access`
/// flags of the `kickstart` tool and configure a VNC password.
public enum RemoteDesktopTemplate {

    /// Generates a remote desktop setup script.
    ///
    /// Creates a temporary shell script that enables Screen Sharing
    /// (VNC) and Remote Login (SSH) on the VM.
    ///
    /// - Returns: A file URL pointing to the generated script in
    ///   a temporary directory.
    /// - Throws: An error if the script cannot be written to disk.
    public static func generate() throws -> URL {
        let url = try ScriptFile.writeToCache(
            script: scriptContent(), fileName: "remote-desktop-setup.sh"
        )
        return url
    }

    /// Generates the shell script content for remote desktop setup.
    ///
    /// Extracted as a separate method for testability.
    ///
    /// ## Why `launchctl`, not `kickstart`
    ///
    /// The provisioner daemon runs the script as root, so the
    /// older `sudo …/ARDAgent.app/Contents/Resources/kickstart
    /// -activate …` form is unnecessary. Modern macOS (12+)
    /// prefers the `launchctl enable` / `launchctl load` pair
    /// — the same command Jamf Pro ships in its documented
    /// `EnableRemoteDesktop` policy for EC2 Mac (*"Automate
    /// the Enrollment of EC2 Mac Instances into Jamf Pro"*,
    /// AWS Partner Network Blog, 2022). AWS's own
    /// [Connect to your Mac instance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-to-mac-instance.html)
    /// docs use the identical two-command sequence for GUI-
    /// access enablement. Using `launchctl` buys forward
    /// compatibility and drops the dependency on the ARD GUI
    /// app's bundle layout.
    ///
    /// - Returns: The complete shell script as a string.
    public static func scriptContent() -> String {
        """
        #!/bin/bash
        set -euo pipefail

        # Spooktacular Remote Desktop template
        # Runs as root via the provisioner LaunchDaemon injected
        # onto the guest disk before first boot (see
        # SpooktacularInfrastructureApple/DiskInjector.installProvisionerDaemon).

        # Enable the Screen Sharing launchd service. This is
        # the modern, Apple-documented way to enable VNC —
        # matches what Jamf Pro's EnableRemoteDesktop policy
        # does on EC2 Mac, and what Apple's own
        # `connect-to-mac-instance.html` doc recommends.
        launchctl enable system/com.apple.screensharing
        launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist

        # Enable Remote Login (SSH). `bootstrap` is idempotent
        # — if SSH is already on, this is a no-op.
        launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true

        echo "Screen Sharing enabled. Connect to this VM via VNC on port 5900."
        """
    }

}

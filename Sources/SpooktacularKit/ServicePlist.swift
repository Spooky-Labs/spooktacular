import Foundation

/// Generates and manages LaunchDaemon plist content for per-VM service daemons.
///
/// Each virtual machine gets its own LaunchDaemon with label
/// `com.spooktacular.vm.<name>` that runs `spook start <name> --headless`.
/// This enables independent lifecycle management of each VM daemon.
///
/// ## Example
///
/// ```swift
/// let plist = ServicePlist.generate(
///     executablePath: "/usr/local/bin/spook",
///     vmName: "runner-01"
/// )
/// ```
public enum ServicePlist {

    /// The LaunchDaemon label prefix for per-VM daemons.
    public static let labelPrefix = "com.spooktacular.vm"

    /// Returns the LaunchDaemon label for a specific VM.
    ///
    /// - Parameter vmName: The name of the virtual machine.
    /// - Returns: A label in the form `com.spooktacular.vm.<vmName>`.
    public static func label(for vmName: String) -> String {
        "\(labelPrefix).\(vmName)"
    }

    /// Returns the plist file path for a specific VM's LaunchDaemon.
    ///
    /// - Parameter vmName: The name of the virtual machine.
    /// - Returns: The absolute path under `/Library/LaunchDaemons/`.
    public static func plistPath(for vmName: String) -> String {
        "/Library/LaunchDaemons/\(label(for: vmName)).plist"
    }

    /// Generates the LaunchDaemon plist XML for a specific VM.
    ///
    /// The daemon runs `spook start <vmName> --headless` and logs to
    /// per-VM log files under `/var/log/`.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the `spook` binary.
    ///   - vmName: The name of the virtual machine to start.
    /// - Returns: A UTF-8 XML string suitable for writing to disk.
    public static func generate(executablePath: String, vmName: String) -> String {
        let daemonLabel = label(for: vmName)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>start</string>
                <string>\(vmName)</string>
                <string>--headless</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>StandardOutPath</key>
            <string>/var/log/spooktacular.\(vmName).log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/spooktacular.\(vmName).error.log</string>
        </dict>
        </plist>
        """
    }
}

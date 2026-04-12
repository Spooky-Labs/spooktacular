import Foundation
import os

/// Executes scripts on a VM via SSH.
///
/// `SSHExecutor` uses the system `ssh` and `scp` binaries
/// (always available on macOS) to connect to a running VM.
/// It provides two main capabilities:
///
/// 1. **Wait for SSH** — Polls port 22 on the VM until it
///    accepts connections, with a configurable timeout.
///
/// 2. **Execute a script** — Copies a local script to the VM
///    via `scp`, then runs it via `ssh`. Standard output and
///    standard error are streamed back to the host in real time.
///
/// ## Usage
///
/// ```swift
/// try await SSHExecutor.waitForSSH(ip: "192.168.64.2")
/// try await SSHExecutor.execute(
///     script: scriptURL,
///     on: "192.168.64.2",
///     user: "admin",
///     key: "~/.ssh/id_ed25519"
/// )
/// ```
///
/// ## Thread Safety
///
/// All methods are `async` and safe to call from any context.
public enum SSHExecutor {

    /// Common SSH options that disable host key checking and
    /// suppress warnings. These are appropriate for ephemeral
    /// VMs where the host key changes on every clone.
    public static let sshOptions: [String] = [
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "ConnectTimeout=5",
    ]

    // MARK: - Wait for SSH

    /// Waits for SSH to become available on the given IP address.
    ///
    /// Polls port 22 every 3 seconds until a TCP connection
    /// succeeds or the timeout expires.
    ///
    /// - Parameters:
    ///   - ip: The VM's IPv4 address.
    ///   - port: The SSH port. Defaults to 22.
    ///   - timeout: Maximum time to wait in seconds. Defaults
    ///     to 120 seconds.
    /// - Throws: ``SSHError/timeout(ip:seconds:)`` if SSH does
    ///   not become available within the timeout.
    public static func waitForSSH(
        ip: String,
        port: Int = 22,
        timeout: TimeInterval = 120
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: UInt64 = 3_000_000_000 // 3 seconds in nanoseconds

        Log.provision.info("Waiting for SSH on \(ip, privacy: .public):\(port)...")

        while Date() < deadline {
            if await isPortOpen(ip: ip, port: port) {
                Log.provision.notice("SSH is available on \(ip, privacy: .public):\(port)")
                return
            }
            Log.provision.debug("SSH not yet available on \(ip, privacy: .public):\(port), retrying in 3s")
            try await Task.sleep(nanoseconds: pollInterval)
        }

        Log.provision.error("SSH connection to \(ip, privacy: .public) timed out after \(Int(timeout)) seconds")
        throw SSHError.timeout(ip: ip, seconds: Int(timeout))
    }

    // MARK: - Execute Script

    /// Copies a script to the VM and executes it via SSH.
    ///
    /// 1. Copies the script to `/tmp/spook-user-data.sh` on the
    ///    guest using `scp`.
    /// 2. Makes the script executable via `ssh ... chmod +x`.
    /// 3. Runs the script via `ssh ... /tmp/spook-user-data.sh`.
    /// 4. Standard output and standard error are inherited by the
    ///    current process, so output streams to the terminal in
    ///    real time.
    ///
    /// - Parameters:
    ///   - script: The local file URL of the shell script to execute.
    ///   - ip: The VM's IPv4 address.
    ///   - user: The SSH user name (e.g., `"admin"`).
    ///   - key: The path to the SSH private key, or `nil` to use
    ///     the SSH agent's default key.
    /// - Throws: ``SSHError/scpFailed(exitCode:)`` if the copy
    ///   fails, or ``SSHError/executionFailed(exitCode:)`` if the
    ///   script exits with a non-zero status.
    public static func execute(
        script: URL,
        on ip: String,
        user: String,
        key: String? = nil
    ) async throws {
        let remotePath = "/tmp/spook-user-data.sh"

        // Step 1: Copy the script to the VM.
        Log.provision.info("Copying script to \(user, privacy: .public)@\(ip, privacy: .public):\(remotePath, privacy: .public)")
        var scpArgs = sshOptions
        if let key {
            let expandedKey = NSString(string: key).expandingTildeInPath
            scpArgs += ["-i", expandedKey]
        }
        scpArgs += [script.path, "\(user)@\(ip):\(remotePath)"]

        let scpExit = try await runStreamingProcess("/usr/bin/scp", arguments: scpArgs)
        guard scpExit == 0 else {
            Log.provision.error("scp failed with exit code \(scpExit) copying script to \(ip, privacy: .public)")
            throw SSHError.scpFailed(exitCode: scpExit)
        }

        // Step 2: Make executable and run.
        Log.provision.info("Executing script on \(ip, privacy: .public)")
        var sshArgs = sshOptions
        if let key {
            let expandedKey = NSString(string: key).expandingTildeInPath
            sshArgs += ["-i", expandedKey]
        }
        sshArgs += ["\(user)@\(ip)", "chmod +x \(remotePath) && \(remotePath)"]

        let sshExit = try await runStreamingProcess("/usr/bin/ssh", arguments: sshArgs)
        guard sshExit == 0 else {
            Log.provision.error("Remote script execution failed with exit code \(sshExit) on \(ip, privacy: .public)")
            throw SSHError.executionFailed(exitCode: sshExit)
        }

        Log.provision.notice("Script completed successfully on \(ip, privacy: .public)")
    }

    // MARK: - Port Check

    /// Checks whether a TCP port is open on the given IP.
    ///
    /// Attempts a non-blocking TCP connection with a short timeout.
    ///
    /// - Parameters:
    ///   - ip: The target IPv4 address.
    ///   - port: The target TCP port.
    /// - Returns: `true` if the connection succeeds.
    static func isPortOpen(ip: String, port: Int) async -> Bool {
        // Use /usr/bin/nc (netcat) with a 2-second timeout for
        // a quick TCP connect check. The -z flag scans without
        // sending data. Available on all macOS versions.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-w", "2", ip, "\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Process Helpers

    /// Runs a process with stdout/stderr inherited (streaming).
    ///
    /// - Parameters:
    ///   - path: The absolute path to the executable.
    ///   - arguments: Command-line arguments.
    /// - Returns: The process's exit code.
    static func runStreamingProcess(
        _ path: String,
        arguments: [String]
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        // Inherit stdout/stderr so output streams to the terminal.
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

// MARK: - Errors

/// An error that occurs during SSH operations.
public enum SSHError: Error, Sendable, LocalizedError, Equatable {

    /// SSH did not become available within the timeout.
    ///
    /// - Parameters:
    ///   - ip: The IP address that was being polled.
    ///   - seconds: The timeout in seconds.
    case timeout(ip: String, seconds: Int)

    /// The `scp` file copy failed.
    ///
    /// - Parameter exitCode: The exit code from the `scp` process.
    case scpFailed(exitCode: Int32)

    /// The remote script execution failed.
    ///
    /// - Parameter exitCode: The exit code from the `ssh` process.
    case executionFailed(exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .timeout(let ip, let seconds):
            "SSH connection to \(ip) timed out after \(seconds) seconds."
        case .scpFailed(let exitCode):
            "Failed to copy script to VM via scp (exit code \(exitCode))."
        case .executionFailed(let exitCode):
            "Remote script execution failed on VM (exit code \(exitCode))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .timeout:
            "Ensure Remote Login (SSH) is enabled in the VM's System Settings > General > Sharing. "
            + "Verify the VM has finished booting and has a network connection."
        case .scpFailed:
            "Check that the SSH key is correct and the remote user has write access to /tmp. "
            + "Verify the VM is reachable with 'spook ip <name>'."
        case .executionFailed:
            "Review the script output above for errors. Connect manually with 'spook ssh <name>' to debug."
        }
    }
}

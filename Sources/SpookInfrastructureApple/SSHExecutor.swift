import Foundation
import SpookCore
import SpookApplication
import Network
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

    /// The SSH host-key trust model Spooktacular should apply.
    ///
    /// The control plane is used against both **ephemeral** VMs
    /// (every clone has a fresh host key — trust-on-first-use is
    /// appropriate) and **persistent** VMs (host keys are stable
    /// and an enterprise auditor expects strict verification).
    /// A single hard-coded policy can't serve both.
    public enum HostKeyTrust: Sendable, Equatable {
        /// Accept any host key. Only safe for freshly-cloned
        /// ephemeral VMs that are destroyed after use. The mode
        /// suppresses SSH's "man-in-the-middle" warning, which is
        /// exactly what you don't want against a persistent VM.
        case acceptAny

        /// Record the host key on first connection, then require
        /// it match on subsequent connections. Host keys are
        /// written to the given path (use a per-VM file to avoid
        /// cross-VM contamination).
        case trustOnFirstUse(knownHostsPath: String)

        /// Require a pre-populated known_hosts file. Rejects any
        /// host whose key isn't already listed. The only mode
        /// appropriate for enterprise deployments.
        case strict(knownHostsPath: String)
    }

    /// The default host-key trust applied when callers don't pass
    /// one. Can be overridden by setting
    /// `SPOOK_SSH_HOST_KEY_TRUST=strict` /
    /// `SPOOK_SSH_KNOWN_HOSTS=...` so operators don't have to
    /// edit source to enforce it.
    public static var defaultHostKeyTrust: HostKeyTrust {
        let env = ProcessInfo.processInfo.environment
        let mode = env["SPOOK_SSH_HOST_KEY_TRUST"]
        let path = env["SPOOK_SSH_KNOWN_HOSTS"]
            ?? "~/.spooktacular/known_hosts".expandingTilde

        switch mode {
        case "strict":  return .strict(knownHostsPath: path)
        case "tofu":    return .trustOnFirstUse(knownHostsPath: path)
        default:        return .trustOnFirstUse(knownHostsPath: path)   // safer default than accept-any
        }
    }

    /// Common SSH options. Host-key policy is injected from the
    /// caller via ``sshOptions(trust:)``; the raw array below
    /// only carries non-trust flags (log level, connect timeout).
    public static let sshOptions: [String] = sshOptions(trust: defaultHostKeyTrust)

    /// Builds the full SSH option list for a given trust mode.
    ///
    /// Factored so callers that operate against ephemeral VMs
    /// (CI clones) can pass ``HostKeyTrust/acceptAny`` locally
    /// without mutating the global default — which previously
    /// left ALL connections in a safe-for-ephemeral-only mode.
    public static func sshOptions(trust: HostKeyTrust) -> [String] {
        var opts: [String] = [
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=5",
        ]
        switch trust {
        case .acceptAny:
            opts += [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
            ]
        case .trustOnFirstUse(let path):
            opts += [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "UserKnownHostsFile=\(path)",
            ]
        case .strict(let path):
            opts += [
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\(path)",
            ]
        }
        return opts
    }

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
        let keyArgs = keyArguments(for: key)

        Log.provision.info("Copying script to \(user, privacy: .public)@\(ip, privacy: .public):\(remotePath, privacy: .public)")
        let scpArgs = sshOptions + keyArgs + [script.path, "\(user)@\(ip):\(remotePath)"]
        let scpExit = try await runStreamingProcess("/usr/bin/scp", arguments: scpArgs)
        guard scpExit == 0 else {
            Log.provision.error("scp failed with exit code \(scpExit) copying script to \(ip, privacy: .public)")
            throw SSHError.scpFailed(exitCode: scpExit)
        }

        Log.provision.info("Executing script on \(ip, privacy: .public)")
        let sshArgs = sshOptions + keyArgs + ["\(user)@\(ip)", "chmod +x \(remotePath) && \(remotePath)"]
        let sshExit = try await runStreamingProcess("/usr/bin/ssh", arguments: sshArgs)
        guard sshExit == 0 else {
            Log.provision.error("Remote script execution failed with exit code \(sshExit) on \(ip, privacy: .public)")
            throw SSHError.executionFailed(exitCode: sshExit)
        }

        Log.provision.notice("Script completed successfully on \(ip, privacy: .public)")
    }

    // MARK: - Interactive Execution

    /// Runs an interactive SSH session with the given arguments.
    ///
    /// Launches `/usr/bin/ssh` with `arguments`, inheriting the
    /// calling process's standard input, output, and error so the
    /// user gets a fully interactive terminal. The method blocks
    /// until the SSH process exits.
    ///
    /// Use this for `spook ssh` and `spook exec`, where the user
    /// interacts directly with the remote shell.
    ///
    /// - Parameter arguments: The argument list for `ssh`,
    ///   including options, identity, and destination.
    /// - Throws: ``SSHError/executionFailed(exitCode:)`` if the
    ///   SSH process exits with a non-zero status.
    public static func execInteractive(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SSHError.executionFailed(exitCode: process.terminationStatus)
        }
    }

    // MARK: - Port Check

    /// Checks whether a TCP port is open on the given IP.
    ///
    /// Uses Network.framework's `NWConnection` for an async-safe
    /// TCP probe that does not block the calling actor.
    ///
    /// - Parameters:
    ///   - ip: The target IPv4 address.
    ///   - port: The target TCP port.
    /// - Returns: `true` if a TCP connection can be established
    ///   within 2 seconds.
    static func isPortOpen(ip: String, port: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ip),
            port: nwPort
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        nonisolated(unsafe) var resumed = false
        let lock = NSLock()

        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }

                switch state {
                case .ready:
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Key Arguments

    /// Builds the `-i <key>` arguments for SSH/SCP commands.
    ///
    /// - Parameter key: The SSH private key path, or `nil` to use
    ///   the SSH agent's default key.
    /// - Returns: An array with `-i` and the expanded path, or
    ///   an empty array if no key was provided.
    private static func keyArguments(for key: String?) -> [String] {
        guard let key else { return [] }
        return ["-i", key.expandingTilde]
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
        process.executableURL = URL(filePath: path)
        process.arguments = arguments

        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
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

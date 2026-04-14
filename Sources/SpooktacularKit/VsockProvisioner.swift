import Foundation
@preconcurrency import Virtualization
import os

/// Provisions a running VM by sending a script over VirtIO socket.
///
/// The guest must have the Spooktacular agent installed, which
/// listens on vsock port 9470 for incoming HTTP requests.
///
/// The provisioner creates a ``GuestAgentClient``, calls
/// ``GuestAgentClient/exec(_:)`` with the script content, and
/// checks the exit code. If the vsock connection fails (agent not
/// installed), it falls back to SSH when an IP address is available.
///
/// ## Usage
///
/// ```swift
/// try await VsockProvisioner.provision(
///     virtualMachine: vm,
///     script: scriptURL,
///     fallbackIP: "192.168.64.2",
///     sshUser: "admin"
/// )
/// ```
///
/// ## Thread Safety
///
/// The ``provision(virtualMachine:script:fallbackIP:sshUser:sshKey:)``
/// method must be called on the main actor because it accesses the
/// `VZVirtualMachine` instance.
public enum VsockProvisioner {

    /// The vsock port the guest agent listens on.
    ///
    /// Port 9470 is chosen to avoid conflicts with well-known
    /// services. The same constant must be used by the guest-side
    /// `spook-agent` binary.
    public static let agentPort: UInt32 = 9470

    // MARK: - Legacy Wire Protocol Helpers

    /// Encodes a script payload as a length-prefixed frame.
    ///
    /// The frame format is a 4-byte big-endian `UInt32` length
    /// followed by the script content as UTF-8 bytes. This helper
    /// is retained for backward compatibility with tests and older
    /// agent versions.
    ///
    /// - Parameter script: The script content to encode.
    /// - Returns: The framed data ready to write to the socket.
    public static func encodeFrame(_ script: String) -> Data {
        let scriptData = Data(script.utf8)
        var length = UInt32(scriptData.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(scriptData)
        return frame
    }

    /// Decodes an exit code from a 4-byte big-endian response.
    ///
    /// Retained for backward compatibility with tests and older
    /// agent versions.
    ///
    /// - Parameter data: Exactly 4 bytes of response data from
    ///   the guest agent.
    /// - Returns: The decoded exit code, or `nil` if the data is
    ///   not exactly 4 bytes.
    public static func decodeExitCode(from data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        return data.withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
    }

    /// Sends a script to the guest agent via VirtIO socket.
    ///
    /// Creates a ``GuestAgentClient`` and calls ``GuestAgentClient/exec(_:)``
    /// with the full script content. If the agent returns a non-zero
    /// exit code, throws ``VsockProvisionerError/scriptFailed(exitCode:)``.
    /// Falls back to SSH provisioning if the vsock connection fails.
    ///
    /// - Parameters:
    ///   - virtualMachine: The running VM to provision.
    ///   - script: The local file URL of the shell script to execute.
    ///   - fallbackIP: An optional IP address for SSH fallback.
    ///     When `nil` and the agent is not responding, the method
    ///     throws ``VsockProvisionerError/agentNotResponding``.
    ///   - sshUser: The SSH user name for fallback. Defaults to `"admin"`.
    ///   - sshKey: The SSH private key path for fallback, or `nil`
    ///     to use the SSH agent's default key.
    /// - Throws: ``VsockProvisionerError`` if the socket device is
    ///   missing or the agent is not responding and no fallback is
    ///   available. ``SSHError`` if the SSH fallback itself fails.
    @MainActor
    public static func provision(
        virtualMachine: VirtualMachine,
        script: URL,
        fallbackIP: String? = nil,
        sshUser: String = "admin",
        sshKey: String? = nil
    ) async throws {
        guard let vzVM = virtualMachine.vzVM,
              let socketDevice = vzVM.socketDevices.first as? VZVirtioSocketDevice else {
            Log.provision.error("No VirtIO socket device found on VM")
            throw VsockProvisionerError.noSocketDevice
        }

        let scriptContent = try String(contentsOf: script, encoding: .utf8)

        Log.provision.info("Attempting vsock connection on port \(agentPort)")

        do {
            let client = GuestAgentClient(socketDevice: socketDevice)
            let result = try await client.exec(scriptContent)

            if result.exitCode != 0 {
                Log.provision.error(
                    "Guest agent reported exit code \(result.exitCode)"
                )
                if !result.stderr.isEmpty {
                    Log.provision.error(
                        "stderr: \(result.stderr, privacy: .public)"
                    )
                }
                throw VsockProvisionerError.scriptFailed(
                    exitCode: result.exitCode
                )
            }

            if !result.stdout.isEmpty {
                Log.provision.info(
                    "stdout: \(result.stdout, privacy: .public)"
                )
            }

            Log.provision.notice("Vsock provisioning complete")

        } catch let error as VsockProvisionerError {
            throw error
        } catch let error as GuestAgentError {
            Log.provision.warning(
                "Guest agent error: \(error.localizedDescription ?? "unknown", privacy: .public)"
            )
            try await sshFallback(
                fallbackIP: fallbackIP, script: script,
                sshUser: sshUser, sshKey: sshKey
            )
        } catch {
            Log.provision.warning(
                "Vsock connection failed: \(error.localizedDescription, privacy: .public)"
            )
            try await sshFallback(
                fallbackIP: fallbackIP, script: script,
                sshUser: sshUser, sshKey: sshKey
            )
        }
    }

    // MARK: - SSH Fallback

    /// Attempts SSH provisioning as a fallback when the vsock agent
    /// is not available.
    ///
    /// - Parameters:
    ///   - fallbackIP: The IP address for SSH, or `nil` to throw.
    ///   - script: The script file URL to execute remotely.
    ///   - sshUser: The SSH user name.
    ///   - sshKey: The SSH private key path, or `nil`.
    /// - Throws: ``VsockProvisionerError/agentNotResponding`` when
    ///   no fallback IP is provided. ``SSHError`` if SSH fails.
    private static func sshFallback(
        fallbackIP: String?,
        script: URL,
        sshUser: String,
        sshKey: String?
    ) async throws {
        Log.provision.info("Falling back to SSH provisioning")

        guard let ip = fallbackIP else {
            throw VsockProvisionerError.agentNotResponding
        }

        Log.provision.info("SSH fallback to \(ip, privacy: .public)")
        try await SSHExecutor.waitForSSH(ip: ip)
        try await SSHExecutor.execute(
            script: script, on: ip, user: sshUser, key: sshKey
        )
    }
}

// MARK: - Errors

/// An error that occurs during vsock provisioning operations.
///
/// Each case provides a specific ``errorDescription`` for display
/// in the CLI, GUI, or logs, and a ``recoverySuggestion`` with
/// actionable guidance for the user.
public enum VsockProvisionerError: Error, LocalizedError, Sendable, Equatable {

    /// The virtual machine does not have a VirtIO socket device.
    case noSocketDevice

    /// The guest agent is not responding on the VirtIO socket.
    ///
    /// This typically means the `spook-agent` binary is not
    /// installed in the guest, or the VM has not finished booting.
    case agentNotResponding

    /// The guest agent executed the script but it exited with
    /// a non-zero status.
    ///
    /// - Parameter exitCode: The script's exit code as reported
    ///   by the agent.
    case scriptFailed(exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .noSocketDevice:
            "The virtual machine does not have a VirtIO socket device configured."
        case .agentNotResponding:
            "The Spooktacular guest agent is not responding on the VirtIO socket."
        case .scriptFailed(let exitCode):
            "Remote script execution via vsock agent failed (exit code \(exitCode))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noSocketDevice:
            "This is an internal error. The socket device should be configured automatically."
        case .agentNotResponding:
            "Install the guest agent in the VM, or use --provision ssh instead."
        case .scriptFailed:
            "Review the script for errors. Connect manually with 'spook ssh <name>' to debug."
        }
    }
}

import Foundation
@preconcurrency import Virtualization
import os

/// Provisions a running VM by sending a script over VirtIO socket.
///
/// The guest must have the Spooktacular agent installed, which
/// listens on vsock port 9470 for incoming script payloads.
/// The protocol is intentionally minimal:
///
/// 1. Host connects to port ``agentPort`` on the guest's vsock device.
/// 2. Host writes the script length as a 4-byte big-endian `UInt32`.
/// 3. Host writes the script content as UTF-8 bytes.
/// 4. Guest agent reads the length, reads that many bytes, executes
///    the script, and writes a 4-byte big-endian exit code back.
/// 5. Host reads the exit code and reports success or failure.
///
/// If the vsock connection fails (agent not installed), the
/// provisioner falls back to SSH when an IP address is available.
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

    // MARK: - Wire Protocol Helpers

    /// Encodes a script payload as a length-prefixed frame.
    ///
    /// The frame format is a 4-byte big-endian `UInt32` length
    /// followed by the script content as UTF-8 bytes.
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
    /// Connects to the VM's vsock device on ``agentPort``,
    /// writes the script content using the length-prefixed protocol,
    /// and waits for the exit code response. Falls back to SSH
    /// provisioning if the vsock connection fails (agent not installed).
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
            let connection = try await socketDevice.connect(toPort: agentPort)

            // VZVirtioSocketConnection provides a raw file descriptor
            // for bidirectional I/O. Create FileHandle wrappers for
            // structured read/write. We duplicate the fd so each
            // handle can close independently without affecting the other.
            let fd = connection.fileDescriptor
            let writeFD = dup(fd)
            let readFD = dup(fd)
            guard writeFD >= 0, readFD >= 0 else {
                Log.provision.error("Failed to duplicate vsock file descriptor")
                throw VsockProvisionerError.agentNotResponding
            }
            let writeHandle = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)
            let readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)

            // Build the payload: 4-byte big-endian length + script bytes.
            let scriptData = Data(scriptContent.utf8)
            var length = UInt32(scriptData.count).bigEndian
            let lengthData = Data(bytes: &length, count: 4)

            writeHandle.write(lengthData)
            writeHandle.write(scriptData)

            Log.provision.info(
                "Script sent via vsock (\(scriptData.count) bytes), waiting for completion"
            )

            // Read the 4-byte exit code response from the agent.
            let responseData = readHandle.readData(ofLength: 4)

            if responseData.count == 4 {
                let exitCode = responseData.withUnsafeBytes {
                    UInt32(bigEndian: $0.load(as: UInt32.self))
                }
                if exitCode != 0 {
                    Log.provision.error("Guest agent reported exit code \(exitCode)")
                    throw VsockProvisionerError.scriptFailed(exitCode: Int32(exitCode))
                }
            }
            // If the agent closes without sending an exit code, treat
            // as success — older agent versions may not send one.

            try? writeHandle.close()
            try? readHandle.close()

            Log.provision.notice("Vsock provisioning complete")

        } catch let error as VsockProvisionerError {
            // Re-throw our own errors without fallback.
            throw error
        } catch {
            // Vsock connection failed — agent likely not installed.
            Log.provision.warning(
                "Vsock connection failed: \(error.localizedDescription, privacy: .public)"
            )
            Log.provision.info("Falling back to SSH provisioning")

            if let ip = fallbackIP {
                Log.provision.info("SSH fallback to \(ip, privacy: .public)")
                try await SSHExecutor.waitForSSH(ip: ip)
                try await SSHExecutor.execute(
                    script: script, on: ip, user: sshUser, key: sshKey
                )
            } else {
                throw VsockProvisionerError.agentNotResponding
            }
        }
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

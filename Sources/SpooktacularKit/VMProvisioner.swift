import Foundation
import os

/// Shared SSH provisioning logic for virtual machines.
///
/// `VMProvisioner` encapsulates the three-step workflow used by
/// both `spook create` (auto-provisioning after install) and
/// `spook start --provision ssh` (post-boot provisioning):
///
/// 1. **Resolve IP** -- Poll the DHCP/ARP tables until the VM's
///    IP address appears, using ``IPResolver/resolveIPWithRetry(macAddress:timeout:pollInterval:)``.
/// 2. **Wait for SSH** -- Poll port 22 until the guest's SSH
///    daemon accepts connections.
/// 3. **Execute script** -- Copy and run the provisioning script
///    on the guest via ``SSHExecutor``.
///
/// By centralizing this workflow in a single type, callers avoid
/// duplicating retry logic and logging, and any improvements
/// (e.g., faster retry backoff, better error messages) apply
/// everywhere.
///
/// ## Usage
///
/// ```swift
/// try await VMProvisioner.provisionViaSSH(
///     macAddress: "aa:bb:cc:dd:ee:ff",
///     script: scriptURL,
///     user: "admin",
///     key: "~/.ssh/id_ed25519"
/// )
/// ```
///
/// ## Thread Safety
///
/// All methods are `async` and safe to call from any context.
public enum VMProvisioner {

    /// Resolves the VM's IP with retry, waits for SSH readiness,
    /// and executes a provisioning script on the guest.
    ///
    /// This is the canonical implementation of SSH-based
    /// provisioning. Both `spook create` and `spook start` delegate
    /// to this method instead of duplicating the resolve-wait-execute
    /// sequence.
    ///
    /// - Parameters:
    ///   - macAddress: The VM's MAC address for IP resolution.
    ///   - script: The local file URL of the shell script to execute.
    ///   - user: The SSH user name. Defaults to `"admin"`.
    ///   - key: Path to the SSH private key, or `nil` to use the
    ///     SSH agent's default key.
    ///   - timeout: Maximum time to wait for IP resolution in
    ///     seconds. Defaults to 120.
    ///   - pollInterval: Seconds between IP resolution retries.
    ///     Defaults to 5.
    /// - Throws: ``SSHError`` if SSH is unreachable or the script
    ///   fails. ``VMProvisionerError/ipResolutionTimedOut(macAddress:timeout:)``
    ///   if no IP address is found within the timeout.
    /// - Returns: The resolved IP address.
    @discardableResult
    public static func provisionViaSSH(
        macAddress: String,
        script: URL,
        user: String = "admin",
        key: String? = nil,
        timeout: TimeInterval = 120,
        pollInterval: TimeInterval = 5
    ) async throws -> String {
        // 1. Resolve the VM's IP address by polling DHCP/ARP.
        Log.provision.info("Resolving IP for MAC \(macAddress, privacy: .public)")
        guard let ip = try await IPResolver.resolveIPWithRetry(
            macAddress: macAddress,
            timeout: timeout,
            pollInterval: pollInterval
        ) else {
            Log.provision.error("Failed to resolve IP for MAC \(macAddress, privacy: .public) within \(Int(timeout))s")
            throw VMProvisionerError.ipResolutionTimedOut(macAddress: macAddress, timeout: timeout)
        }
        Log.provision.notice("Resolved IP \(ip, privacy: .public) for MAC \(macAddress, privacy: .public)")

        // 2. Wait for SSH to become available.
        Log.provision.info("Waiting for SSH on \(ip, privacy: .public)")
        try await SSHExecutor.waitForSSH(ip: ip)
        Log.provision.notice("SSH available on \(ip, privacy: .public)")

        // 3. Execute the provisioning script.
        Log.provision.info("Executing provisioning script on \(ip, privacy: .public)")
        try await SSHExecutor.execute(
            script: script,
            on: ip,
            user: user,
            key: key
        )
        Log.provision.notice("Provisioning script completed on \(ip, privacy: .public)")

        return ip
    }
}

// MARK: - Errors

/// An error that occurs during VM provisioning operations.
public enum VMProvisionerError: Error, LocalizedError, Sendable, Equatable {

    /// IP address resolution timed out for the given MAC address.
    ///
    /// - Parameters:
    ///   - macAddress: The MAC address that was being resolved.
    ///   - timeout: The timeout duration in seconds.
    case ipResolutionTimedOut(macAddress: String, timeout: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .ipResolutionTimedOut(let macAddress, let timeout):
            "Could not resolve an IP address for MAC \(macAddress) within \(Int(timeout)) seconds."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .ipResolutionTimedOut:
            "Ensure the VM has booted and obtained a network address. "
            + "Check that the VM's network configuration uses NAT or bridged mode."
        }
    }
}

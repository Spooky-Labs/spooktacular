/// The network configuration mode for a virtual machine.
///
/// Each mode maps to a specific `Virtualization.framework` network
/// device attachment type. The mode determines how the guest's
/// network traffic is routed relative to the host and the
/// external network.
///
/// ## Choosing a Network Mode
///
/// | Mode | Guest → Internet | Host → Guest | Entitlement |
/// |------|-----------------|--------------|-------------|
/// | ``nat`` | ✓ | Via resolved IP | None |
/// | ``bridged(interface:)`` | ✓ | Own LAN IP | `com.apple.vm.networking` |
/// | ``isolated`` | ✗ | ✗ | None |
/// | ``hostOnly`` | ✗ | ✓ | None |
///
/// - Note: Bridged mode requires the `com.apple.vm.networking`
///   restricted entitlement, which must be requested from Apple
///   Developer Technical Support.
public enum NetworkMode: Sendable, Codable, Equatable, Hashable {

    /// Network address translation through the host.
    ///
    /// The guest can reach the internet via the host's connection.
    /// The host can reach the guest by resolving its DHCP-assigned IP.
    /// No special entitlement required.
    ///
    /// Maps to `VZNATNetworkDeviceAttachment`.
    case nat

    /// Bridged directly to a physical network interface.
    ///
    /// The guest receives its own IP address on the host's LAN
    /// via DHCP. Full bidirectional connectivity.
    ///
    /// Maps to `VZBridgedNetworkDeviceAttachment`.
    ///
    /// - Parameter interface: The host network interface name
    ///   (for example, `"en0"`).
    case bridged(interface: String)

    /// No network connectivity.
    ///
    /// The virtual machine has no network interface attached.
    /// Use this for secure builds where network isolation is required.
    case isolated

    /// Host-only networking.
    ///
    /// The guest can communicate with the host and other VMs
    /// on the same host, but cannot reach the external network.
    ///
    /// Maps to `VZFileHandleNetworkDeviceAttachment` with a
    /// user-space virtual switch.
    case hostOnly
}

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
///
/// For host-guest communication without full network access,
/// use ``isolated`` mode and communicate via the VirtIO socket
/// device (`VZVirtioSocketDeviceConfiguration`), which is always
/// attached regardless of network mode.
///
/// - Note: Bridged mode requires the `com.apple.vm.networking`
///   restricted entitlement, which must be requested from Apple
///   Developer Technical Support.
///
/// ### Why There Is No Host-Only Mode
///
/// Apple's Virtualization framework provides three network
/// attachment types: `VZNATNetworkDeviceAttachment`,
/// `VZBridgedNetworkDeviceAttachment`, and
/// `VZFileHandleNetworkDeviceAttachment`. None of these
/// implements host-only semantics directly.
///
/// A host-only mode would require a user-space virtual network
/// switch built on top of `VZFileHandleNetworkDeviceAttachment`,
/// handling raw Ethernet frames, DHCP, and packet routing — a
/// substantial subsystem that would need its own lifecycle
/// management and security hardening. Rather than ship a
/// half-baked implementation or silently fall back to NAT
/// (which would give VMs unintended internet access), this enum
/// only exposes modes that the Virtualization framework supports
/// natively.
///
/// If you need isolated host-guest communication, use ``isolated``
/// with the VirtIO socket device. If you need full IP networking
/// between VMs, use ``bridged(interface:)`` on a dedicated
/// host-only network interface.
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
    /// Host-guest communication is still possible via the VirtIO
    /// socket device (`VZVirtioSocketDeviceConfiguration`), which
    /// is always attached regardless of network mode.
    case isolated
}

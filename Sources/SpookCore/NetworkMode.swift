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

    /// A stable, machine-readable string representation of this network mode.
    ///
    /// Returns `"nat"`, `"bridged:<interface>"`, or `"isolated"`.
    /// Use this for serialization, JSON APIs, and CLI `--field` output.
    public var serialized: String {
        switch self {
        case .nat: "nat"
        case .bridged(let interface): "bridged:\(interface)"
        case .isolated: "isolated"
        }
    }

    /// Creates a network mode from its serialized string representation.
    ///
    /// Accepts `"nat"`, `"isolated"`, or `"bridged:<interface>"`.
    ///
    /// ```swift
    /// let mode = NetworkMode(serialized: "bridged:en0")
    /// // .bridged(interface: "en0")
    /// ```
    ///
    /// - Parameter serialized: The serialized string.
    /// - Returns: The parsed network mode, or `nil` if the string
    ///   is not recognized.
    public init?(serialized: String) {
        switch serialized {
        case "nat": self = .nat
        case "isolated": self = .isolated
        default:
            if serialized.hasPrefix("bridged:") {
                self = .bridged(interface: String(serialized.dropFirst("bridged:".count)))
            } else {
                return nil
            }
        }
    }

    // MARK: - Codable

    /// Encodes the network mode as a plain string using ``serialized``.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serialized)
    }

    /// Decodes a network mode from its serialized string representation.
    ///
    /// Supports the canonical format (`"nat"`, `"isolated"`,
    /// `"bridged:<interface>"`) and falls back to the compiler-
    /// synthesized keyed format for backward compatibility with
    /// existing `config.json` files.
    public init(from decoder: Decoder) throws {
        // Try single-value (canonical) format first.
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self),
           let mode = NetworkMode(serialized: string) {
            self = mode
            return
        }

        // Fall back to synthesized keyed format for migration.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.nat) {
            self = .nat
        } else if container.contains(.isolated) {
            self = .isolated
        } else if let nested = try? container.nestedContainer(
            keyedBy: BridgedKeys.self, forKey: .bridged
        ) {
            let interface = try nested.decode(String.self, forKey: .interface)
            self = .bridged(interface: interface)
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown NetworkMode format"
                )
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case nat, isolated, bridged
    }

    private enum BridgedKeys: String, CodingKey {
        case interface
    }
}

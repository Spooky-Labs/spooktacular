import Foundation
import Virtualization
import vmnet
import SpooktacularCore
import os

/// A prepared, not-yet-created vmnet network configuration.
///
/// Configuration and creation are separate types because the
/// entitlement boundary falls between them: any process can build a
/// configuration, but only one signed with
/// `com.apple.security.virtualization` can turn it into a live network.
/// Splitting them keeps the buildable half unit-testable.
public final class VmnetNetworkConfiguration: @unchecked Sendable {

    /// The underlying vmnet configuration handle.
    let handle: vmnet_network_configuration_ref

    /// The DHCP-reserved guest address this network will hand out.
    public let guestAddress: String

    /// The port mappings baked into the configuration.
    public let publications: [PortPublication]

    init(
        handle: vmnet_network_configuration_ref,
        guestAddress: String,
        publications: [PortPublication]
    ) {
        self.handle = handle
        self.guestAddress = guestAddress
        self.publications = publications
    }

    deinit {
        // vmnet's configuration and network handles are genuine
        // Core Foundation objects (verified: CFGetTypeID reports
        // "vmnet_network_configuration"), and the framework header
        // directs callers to release them with CFRelease. Swift makes
        // CFRelease unavailable, so the equivalent Unmanaged release
        // balances the +1 from vmnet_network_configuration_create.
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(handle)).release()
    }
}

/// A live vmnet network dedicated to one VM.
///
/// Each VM gets its own shared-mode network so its address can be
/// pinned with a DHCP reservation and its services published to the
/// host through vmnet's own port forwarding — the documented
/// equivalent of `docker -p`, needing no guest software and no
/// IP discovery.
///
/// Apple restricts a network to the process that created it ("to
/// ensure proper isolation between application processes, a virtual
/// machine can only use the network that the same application process
/// creates"), so this type is always constructed by whichever process
/// starts the VM.
public final class VmnetNetwork: @unchecked Sendable {

    private let network: vmnet_network_ref
    private static let log = Logger(subsystem: "com.spooktacular", category: "vmnet")

    private init(network: vmnet_network_ref) {
        self.network = network
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(network)).release()
    }

    /// The Virtualization attachment for this network.
    public var attachment: VZVmnetNetworkDeviceAttachment {
        VZVmnetNetworkDeviceAttachment(network: network)
    }

    /// Builds a network configuration: subnet, DHCP reservation, and
    /// one forwarding rule per publication.
    ///
    /// The subnet is set explicitly rather than left to the framework
    /// because a reservation must name an address *before* the network
    /// is created, while vmnet's default subnet is only chosen at
    /// creation — too late to reserve within.
    ///
    /// - Parameters:
    ///   - allocation: Subnet and reserved address for this VM.
    ///   - macAddress: The VM's MAC, which the reservation keys on.
    ///   - publications: Host-to-guest port mappings.
    /// - Returns: A configuration ready for ``create(from:)``.
    /// - Throws: ``VmnetError`` when vmnet rejects any step.
    public static func configure(
        allocation: GuestNetworkAllocation,
        macAddress: MACAddress,
        publications: [PortPublication]
    ) throws -> VmnetNetworkConfiguration {
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let handle = vmnet_network_configuration_create(
            operating_modes_t.VMNET_SHARED_MODE,
            &status
        ) else {
            throw VmnetError.configurationFailed(Int32(status.rawValue))
        }
        // From here on, `configuration` owns the handle: letting it go
        // out of scope on a thrown error releases it.
        let configuration = VmnetNetworkConfiguration(
            handle: handle,
            guestAddress: allocation.guestAddress,
            publications: publications
        )

        var subnet = in_addr()
        var mask = in_addr()
        guard inet_pton(AF_INET, allocation.subnetAddress, &subnet) == 1,
              inet_pton(AF_INET, allocation.subnetMask, &mask) == 1 else {
            throw VmnetError.subnetRejected(0)
        }
        let subnetResult = vmnet_network_configuration_set_ipv4_subnet(handle, &subnet, &mask)
        guard subnetResult == vmnet_return_t.VMNET_SUCCESS else {
            throw VmnetError.subnetRejected(Int32(subnetResult.rawValue))
        }

        var guestAddress = in_addr()
        guard inet_pton(AF_INET, allocation.guestAddress, &guestAddress) == 1 else {
            throw VmnetError.reservationRejected(0)
        }
        var ethernet = try etherAddress(from: macAddress)
        let reservationResult = vmnet_network_configuration_add_dhcp_reservation(
            handle,
            &ethernet,
            &guestAddress
        )
        guard reservationResult == vmnet_return_t.VMNET_SUCCESS else {
            throw VmnetError.reservationRejected(Int32(reservationResult.rawValue))
        }

        for publication in publications {
            let ruleResult = withUnsafePointer(to: &guestAddress) { pointer in
                vmnet_network_configuration_add_port_forwarding_rule(
                    handle,
                    UInt8(IPPROTO_TCP),
                    sa_family_t(AF_INET),
                    publication.guestPort,
                    publication.hostPort,
                    UnsafeRawPointer(pointer)
                )
            }
            guard ruleResult == vmnet_return_t.VMNET_SUCCESS else {
                throw VmnetError.forwardingRuleRejected(
                    hostPort: publication.hostPort,
                    status: Int32(ruleResult.rawValue)
                )
            }
        }

        return configuration
    }

    /// Creates the live network.
    ///
    /// Requires the `com.apple.security.virtualization` entitlement: an
    /// unentitled process gets `VMNET_MEM_FAILURE` here even though
    /// every configuration call above succeeded.
    ///
    /// - Parameter configuration: A configuration from
    ///   ``configure(allocation:macAddress:publications:)``.
    /// - Returns: The live network.
    /// - Throws: ``VmnetError/networkCreationFailed(_:)``.
    public static func create(from configuration: VmnetNetworkConfiguration) throws -> VmnetNetwork {
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let network = vmnet_network_create(configuration.handle, &status) else {
            throw VmnetError.networkCreationFailed(Int32(status.rawValue))
        }
        log.notice(
            "vmnet network created for guest \(configuration.guestAddress, privacy: .public) with \(configuration.publications.count) published port(s)"
        )
        return VmnetNetwork(network: network)
    }

    /// Converts a ``MACAddress`` to the C `ether_addr_t` vmnet expects.
    private static func etherAddress(from macAddress: MACAddress) throws -> ether_addr_t {
        let bytes = macAddress.rawValue.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { throw VmnetError.reservationRejected(0) }
        var address = ether_addr_t()
        withUnsafeMutableBytes(of: &address) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        return address
    }
}

/// Diagnostics for vmnet network setup.
public enum VmnetError: Error, Sendable, Equatable, LocalizedError {

    /// The configuration object could not be created.
    case configurationFailed(Int32)

    /// The subnet was rejected, or could not be parsed.
    case subnetRejected(Int32)

    /// The DHCP reservation was rejected, or the address could not be parsed.
    case reservationRejected(Int32)

    /// A port-forwarding rule was rejected.
    case forwardingRuleRejected(hostPort: UInt16, status: Int32)

    /// The network could not be created.
    case networkCreationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .configurationFailed(let status):
            "Could not create a vmnet network configuration (status \(status))."
        case .subnetRejected(let status):
            "vmnet rejected the subnet for this VM (status \(status))."
        case .reservationRejected(let status):
            "vmnet rejected the DHCP address reservation for this VM (status \(status))."
        case .forwardingRuleRejected(let hostPort, let status):
            "vmnet rejected the port publication for host port \(hostPort) (status \(status))."
        case .networkCreationFailed(let status):
            "Could not create the vmnet network (status \(status))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .networkCreationFailed:
            "Creating a network requires the com.apple.security.virtualization entitlement — run the signed Spooktacular.app or its bundled `spook` binary rather than an unsigned build."
        case .forwardingRuleRejected:
            "Choose a different host port with --publish."
        case .subnetRejected, .reservationRejected:
            "Delete VMs you no longer need to free a subnet, then try again."
        case .configurationFailed:
            "Check Console.app for vmnet errors, then retry."
        }
    }
}

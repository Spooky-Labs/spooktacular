import Foundation

/// The private IPv4 network assigned to a single VM.
///
/// Each VM gets its own `/24` so that its guest address can be pinned
/// by a DHCP reservation before the network starts: vmnet refuses to
/// modify reservations on a live network, and its default subnet is
/// only chosen when the network is created — too late to name an
/// address in advance. Recording the allocation in bundle metadata
/// also makes `spook ip` a constant-time lookup instead of a
/// lease-file scrape.
///
/// The framework reserves three addresses in every subnet: the first
/// is unassignable, the second belongs to the host, and the last is
/// the broadcast address. Guests therefore start at `.3`.
public struct GuestNetworkAllocation: Sendable, Codable, Equatable {

    /// The subnet address, for example `192.168.211.0`.
    public let subnetAddress: String

    /// The subnet mask, always `255.255.255.0`.
    public let subnetMask: String

    /// The address reserved for this VM, for example `192.168.211.3`.
    public let guestAddress: String

    /// Creates an allocation from explicit values.
    ///
    /// - Parameters:
    ///   - subnetAddress: Dotted-quad subnet address.
    ///   - subnetMask: Dotted-quad mask.
    ///   - guestAddress: The DHCP-reserved guest address.
    public init(subnetAddress: String, subnetMask: String, guestAddress: String) {
        self.subnetAddress = subnetAddress
        self.subnetMask = subnetMask
        self.guestAddress = guestAddress
    }

    /// The third octet of the subnet — the value that distinguishes
    /// one VM's network from another's. Returns `-1` when the stored
    /// address is not a dotted quad.
    public var thirdOctet: Int {
        let octets = subnetAddress.split(separator: ".")
        guard octets.count == 4, let third = Int(octets[2]) else { return -1 }
        return third
    }

    /// The lowest third octet this allocator hands out.
    ///
    /// Values below 64 are left alone: macOS uses `192.168.64.0/24`
    /// for its own default shared network, and staying above it keeps
    /// Spooktacular's per-VM networks clear of the system's.
    private static let lowestOctet = 64

    /// The highest third octet this allocator hands out. `.255` is
    /// avoided because a `192.168.255.0/24` subnet is a common
    /// convention for other tooling.
    private static let highestOctet = 254

    /// Allocates the next free `/24`.
    ///
    /// - Parameter used: Third octets already taken by other VMs.
    /// - Returns: A fresh allocation whose subnet is unused.
    /// - Throws: ``GuestNetworkAllocationError/poolExhausted`` when
    ///   every candidate subnet is taken.
    public static func allocate(avoiding used: Set<Int>) throws -> GuestNetworkAllocation {
        for octet in lowestOctet...highestOctet where !used.contains(octet) {
            return GuestNetworkAllocation(
                subnetAddress: "192.168.\(octet).0",
                subnetMask: "255.255.255.0",
                guestAddress: "192.168.\(octet).3"
            )
        }
        throw GuestNetworkAllocationError.poolExhausted
    }
}

/// Diagnostics for guest-network allocation.
public enum GuestNetworkAllocationError: Error, Sendable, Equatable, LocalizedError {

    /// Every candidate subnet is already assigned to another VM.
    case poolExhausted

    public var errorDescription: String? {
        "No free private subnet is available for a new VM."
    }

    public var recoverySuggestion: String? {
        "Delete VMs you no longer need — each VM reserves one 192.168.x.0/24 subnet."
    }
}

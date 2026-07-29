import Testing
import Foundation
@testable import SpooktacularCore

@Suite("GuestNetworkAllocation", .tags(.networking))
struct GuestNetworkAllocationTests {

    @Test("allocates a /24 in the private range with a usable guest address")
    func allocatesUsable() throws {
        let allocation = try GuestNetworkAllocation.allocate(avoiding: [])
        #expect(allocation.subnetMask == "255.255.255.0")
        #expect(allocation.subnetAddress.hasPrefix("192.168."))
        #expect(allocation.subnetAddress.hasSuffix(".0"))
        // The framework reserves .1 (unassignable), .2 (host) and .255.
        #expect(allocation.guestAddress.hasSuffix(".3"))
        #expect(allocation.thirdOctet >= 64)
    }

    @Test("guest address sits inside its own subnet")
    func guestInsideSubnet() throws {
        let allocation = try GuestNetworkAllocation.allocate(avoiding: [])
        let subnetPrefix = allocation.subnetAddress
            .split(separator: ".")
            .dropLast()
            .joined(separator: ".")
        #expect(allocation.guestAddress.hasPrefix(subnetPrefix + "."))
    }

    @Test("avoids third octets already in use")
    func avoidsUsed() throws {
        let used = Set(64...200)
        let allocation = try GuestNetworkAllocation.allocate(avoiding: used)
        #expect(!used.contains(allocation.thirdOctet))
    }

    @Test("throws when the pool is exhausted")
    func poolExhausted() {
        let everything = Set(0...255)
        #expect(throws: GuestNetworkAllocationError.poolExhausted) {
            try GuestNetworkAllocation.allocate(avoiding: everything)
        }
    }

    @Test("round-trips through JSON")
    func codableRoundTrip() throws {
        let original = GuestNetworkAllocation(
            subnetAddress: "192.168.211.0",
            subnetMask: "255.255.255.0",
            guestAddress: "192.168.211.3"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(GuestNetworkAllocation.self, from: data) == original)
        #expect(original.thirdOctet == 211)
    }
}

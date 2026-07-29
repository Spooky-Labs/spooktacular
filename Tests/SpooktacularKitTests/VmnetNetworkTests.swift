import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularInfrastructureApple

/// Only configuration building is covered here. `vmnet_network_create`
/// requires the `com.apple.security.virtualization` entitlement — an
/// unsigned test binary gets `VMNET_MEM_FAILURE` from it even though
/// every configuration call succeeds — so creating a live network is
/// exercised by the gated live-validation script instead.
@Suite("VmnetNetwork configuration", .tags(.networking))
struct VmnetNetworkTests {

    private let allocation = GuestNetworkAllocation(
        subnetAddress: "192.168.211.0",
        subnetMask: "255.255.255.0",
        guestAddress: "192.168.211.3"
    )

    @Test("builds a configuration carrying the reserved address and rules")
    func buildsConfiguration() throws {
        let configuration = try VmnetNetwork.configure(
            allocation: allocation,
            macAddress: MACAddress.generate(),
            publications: [PortPublication(hostPort: 8080, guestPort: 18789)]
        )
        #expect(configuration.guestAddress == "192.168.211.3")
        #expect(configuration.publications == [PortPublication(hostPort: 8080, guestPort: 18789)])
    }

    @Test("accepts an empty publication list")
    func noPublications() throws {
        let configuration = try VmnetNetwork.configure(
            allocation: allocation,
            macAddress: MACAddress.generate(),
            publications: []
        )
        #expect(configuration.publications.isEmpty)
    }

    @Test("accepts several publications")
    func manyPublications() throws {
        let publications = [
            PortPublication(hostPort: 18789, guestPort: 18789),
            PortPublication(hostPort: 2222, guestPort: 22),
        ]
        let configuration = try VmnetNetwork.configure(
            allocation: allocation,
            macAddress: MACAddress.generate(),
            publications: publications
        )
        #expect(configuration.publications == publications)
    }

    @Test("rejects a malformed subnet")
    func rejectsBadSubnet() {
        let bad = GuestNetworkAllocation(
            subnetAddress: "not-an-address",
            subnetMask: "255.255.255.0",
            guestAddress: "192.168.211.3"
        )
        #expect(throws: VmnetError.subnetRejected(0)) {
            try VmnetNetwork.configure(
                allocation: bad,
                macAddress: MACAddress.generate(),
                publications: []
            )
        }
    }

    @Test("rejects a malformed guest address")
    func rejectsBadGuestAddress() {
        let bad = GuestNetworkAllocation(
            subnetAddress: "192.168.211.0",
            subnetMask: "255.255.255.0",
            guestAddress: "also-bad"
        )
        #expect(throws: VmnetError.reservationRejected(0)) {
            try VmnetNetwork.configure(
                allocation: bad,
                macAddress: MACAddress.generate(),
                publications: []
            )
        }
    }

    @Test("an unentitled process cannot create a live network")
    func creationRequiresEntitlement() throws {
        // Documents the entitlement boundary this suite is built
        // around: configuration succeeds, creation does not. If this
        // ever starts passing in the unsigned test runner, the boundary
        // moved and the live gate should be revisited.
        let configuration = try VmnetNetwork.configure(
            allocation: allocation,
            macAddress: MACAddress.generate(),
            publications: []
        )
        #expect(throws: (any Error).self) {
            _ = try VmnetNetwork.create(from: configuration)
        }
    }
}

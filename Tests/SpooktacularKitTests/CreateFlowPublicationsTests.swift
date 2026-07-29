import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication

@Suite("Create flow publications", .tags(.cli))
struct CreateFlowPublicationsTests {

    private let gateway = PortPublication(hostPort: 18789, guestPort: 18789)

    @Test("a template default is kept when the operator publishes nothing")
    func templateOnly() {
        #expect(CreateFlowPublications.merge(template: [gateway], operator: []) == [gateway])
    }

    @Test("operator publications are kept when there is no template default")
    func operatorOnly() {
        let explicit = PortPublication(hostPort: 2222, guestPort: 22)
        #expect(CreateFlowPublications.merge(template: [], operator: [explicit]) == [explicit])
    }

    @Test("template and operator publications combine when they don't clash")
    func combines() {
        let explicit = PortPublication(hostPort: 2222, guestPort: 22)
        let merged = CreateFlowPublications.merge(template: [gateway], operator: [explicit])
        #expect(merged.count == 2)
        #expect(merged.contains(gateway))
        #expect(merged.contains(explicit))
    }

    @Test("an operator publication replaces a template default on the same host port")
    func operatorWinsOnConflict() {
        // vmnet cannot hold two rules for one host port, so the
        // operator's intent must displace the default rather than
        // sitting alongside it.
        let override = PortPublication(hostPort: 18789, guestPort: 9999)
        #expect(CreateFlowPublications.merge(template: [gateway], operator: [override]) == [override])
    }

    @Test("merged publications never contain a duplicate host port")
    func noDuplicateHostPorts() {
        let override = PortPublication(hostPort: 18789, guestPort: 9999)
        let other = PortPublication(hostPort: 2222, guestPort: 22)
        let merged = CreateFlowPublications.merge(template: [gateway], operator: [override, other])
        #expect(Swift.Set(merged.map(\.hostPort)).count == merged.count)
    }

    @Test("subnet allocation avoids octets already used by existing VMs")
    func allocationAvoidsExisting() throws {
        let existing = [
            GuestNetworkAllocation(
                subnetAddress: "192.168.64.0",
                subnetMask: "255.255.255.0",
                guestAddress: "192.168.64.3"
            ),
            GuestNetworkAllocation(
                subnetAddress: "192.168.65.0",
                subnetMask: "255.255.255.0",
                guestAddress: "192.168.65.3"
            ),
        ]
        let allocation = try GuestNetworkAllocation.allocate(
            avoiding: Swift.Set(existing.map(\.thirdOctet))
        )
        #expect(allocation.thirdOctet != 64)
        #expect(allocation.thirdOctet != 65)
    }
}

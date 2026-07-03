import Testing
import Foundation
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularCore

/// Tests for the `remove` vs `removeForce` contract on
/// ``InMemoryTenantRegistry`` — previously `remove` was documented
/// as "fails if the tenant has active VMs" but the implementation
/// always succeeded silently, leaving the door open for dangling
/// tenant-less VMs.
@Suite("TenantRegistry remove contract", .tags(.security))
struct TenantRegistryRemoveTests {

    @Test("remove with no counter configured deletes the tenant")
    func removeWithoutCounterSucceeds() async throws {
        let registry = InMemoryTenantRegistry()
        try await registry.register(TenantDefinition(id: "t1", name: "t1"))
        try await registry.remove(id: "t1")
        let remaining = await registry.tenant(id: "t1")
        #expect(remaining == nil)
    }

    @Test("remove refuses to delete when the counter reports active VMs")
    func removeBlockedByActiveVMs() async throws {
        let registry = InMemoryTenantRegistry(
            activeVMCounter: { _ in 3 }
        )
        try await registry.register(TenantDefinition(id: "t1", name: "t1"))
        await #expect(throws: TenantRegistryError.tenantHasActiveVMs(id: "t1", count: 3)) {
            try await registry.remove(id: "t1")
        }
        let stillThere = await registry.tenant(id: "t1")
        #expect(stillThere != nil, "Tenant must remain when remove is rejected")
    }

    @Test("remove succeeds when counter reports zero active VMs")
    func removeSucceedsAtZeroActive() async throws {
        let registry = InMemoryTenantRegistry(
            activeVMCounter: { _ in 0 }
        )
        try await registry.register(TenantDefinition(id: "t1", name: "t1"))
        try await registry.remove(id: "t1")
        #expect(await registry.tenant(id: "t1") == nil)
    }

    @Test("removeForce orphans active VMs and deletes the tenant")
    func removeForceOrphansVMs() async throws {
        let registry = InMemoryTenantRegistry(
            activeVMCounter: { _ in 7 }
        )
        try await registry.register(TenantDefinition(id: "t1", name: "t1"))
        try await registry.removeForce(id: "t1")
        #expect(await registry.tenant(id: "t1") == nil)
    }

    @Test("remove on unknown tenant throws notFound even when counter reports zero")
    func removeOnUnknownTenantThrows() async {
        let registry = InMemoryTenantRegistry(
            activeVMCounter: { _ in 0 }
        )
        await #expect(throws: TenantRegistryError.notFound("missing")) {
            try await registry.remove(id: "missing")
        }
    }
}

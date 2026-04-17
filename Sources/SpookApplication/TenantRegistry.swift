import Foundation
import SpookCore

/// Runtime registry for managing tenants and host pools.
///
/// Tenants are first-class domain objects, not external JSON.
/// The registry supports dynamic registration, updates, and
/// removal without restarting the controller.
public protocol TenantRegistry: Sendable {
    /// Registers a new tenant with its host pool assignments.
    func register(_ tenant: TenantDefinition) async throws

    /// Updates an existing tenant's configuration.
    func update(_ tenant: TenantDefinition) async throws

    /// Removes a tenant.
    ///
    /// Fails with ``TenantRegistryError/tenantHasActiveVMs(id:count:)``
    /// when the tenant still has VMs attributed to it. Callers that
    /// deliberately want to orphan those VMs (tenancy decommission,
    /// emergency eviction) must call ``removeForce(id:)`` instead —
    /// "silent remove that leaves VMs dangling" is exactly the kind
    /// of ambiguity the audit sweep is purging.
    ///
    /// - Parameter id: Tenant identifier.
    /// - Throws: ``TenantRegistryError/notFound(_:)`` when the tenant
    ///   does not exist; ``TenantRegistryError/tenantHasActiveVMs(id:count:)``
    ///   when VMs still reference the tenant.
    func remove(id: String) async throws

    /// Removes a tenant even when it has active VMs, orphaning them.
    ///
    /// Use in controlled decommission flows where the caller has
    /// already disposed of the VMs or will do so out-of-band. Emits
    /// the same persistence side-effects as ``remove(id:)``.
    ///
    /// - Parameter id: Tenant identifier.
    /// - Throws: ``TenantRegistryError/notFound(_:)`` when the tenant
    ///   does not exist.
    func removeForce(id: String) async throws

    /// Returns all registered tenants.
    func allTenants() async -> [TenantDefinition]

    /// Returns a specific tenant by ID.
    func tenant(id: String) async -> TenantDefinition?

    /// Builds a TenantIsolationPolicy from the current registry state.
    func buildIsolationPolicy() async -> any TenantIsolationPolicy
}

/// Injectable probe for active-VM counts.
///
/// The registry itself doesn't own VM state — VMs live in
/// `~/.spooktacular/vms/`. Callers pass a counter closure at
/// construction time so the registry can enforce the `remove`
/// contract without taking a dependency on the filesystem layer.
///
/// The closure is `async` because real implementations
/// (`FileManager.contentsOfDirectory`) may block, and `throws` so a
/// probe failure can be surfaced as an authorization error rather
/// than a silent zero.
public typealias TenantActiveVMCounter = @Sendable (_ tenantID: String) async throws -> Int

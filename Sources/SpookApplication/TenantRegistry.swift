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

    /// Removes a tenant. Fails if the tenant has active VMs.
    func remove(id: String) async throws

    /// Returns all registered tenants.
    func allTenants() async -> [TenantDefinition]

    /// Returns a specific tenant by ID.
    func tenant(id: String) async -> TenantDefinition?

    /// Builds a TenantIsolationPolicy from the current registry state.
    func buildIsolationPolicy() async -> any TenantIsolationPolicy
}

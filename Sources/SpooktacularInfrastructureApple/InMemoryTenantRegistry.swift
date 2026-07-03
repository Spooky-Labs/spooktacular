import Foundation
import SpooktacularCore
import SpooktacularApplication

/// In-memory tenant registry with optional file persistence.
///
/// Supports runtime registration and removal of tenants.
/// Optionally persists to a JSON file for restart recovery.
///
/// ## remove vs. removeForce
///
/// The registry does not own VM state — VMs live under
/// `~/.spooktacular/vms/`. To enforce the ``TenantRegistry/remove(id:)``
/// contract ("fails when the tenant has active VMs") callers pass a
/// ``TenantActiveVMCounter`` closure at construction that the registry
/// calls before committing the removal. Callers that cannot supply a
/// counter — tests, single-tenant setups, migration scripts — will
/// see ``remove(id:)`` behave identically to ``removeForce(id:)``,
/// which is logged at warning level so operators don't silently get
/// the lax behavior without knowing.
public actor InMemoryTenantRegistry: TenantRegistry {
    private var tenants: [String: TenantDefinition] = [:]
    private let persistPath: String?
    private let activeVMCounter: TenantActiveVMCounter?

    public init(
        persistPath: String? = nil,
        activeVMCounter: TenantActiveVMCounter? = nil
    ) {
        self.persistPath = persistPath
        self.activeVMCounter = activeVMCounter
        // Load from file if it exists
        if let path = persistPath,
           let data = try? Data(contentsOf: URL(filePath: path)),
           let loaded = try? JSONDecoder().decode([TenantDefinition].self, from: data) {
            for t in loaded { tenants[t.id] = t }
        }
    }

    /// Convenience: init from SpooktacularConfig
    public init(
        config: SpooktacularConfig,
        persistPath: String? = nil,
        activeVMCounter: TenantActiveVMCounter? = nil
    ) {
        self.persistPath = persistPath
        self.activeVMCounter = activeVMCounter
        for t in config.tenants { tenants[t.id] = t }
    }

    public func register(_ tenant: TenantDefinition) async throws {
        tenants[tenant.id] = tenant
        try await persist()
    }

    public func update(_ tenant: TenantDefinition) async throws {
        guard tenants[tenant.id] != nil else {
            throw TenantRegistryError.notFound(tenant.id)
        }
        tenants[tenant.id] = tenant
        try await persist()
    }

    public func remove(id: String) async throws {
        guard tenants[id] != nil else {
            throw TenantRegistryError.notFound(id)
        }
        if let counter = activeVMCounter {
            let active = try await counter(id)
            if active > 0 {
                throw TenantRegistryError.tenantHasActiveVMs(id: id, count: active)
            }
        }
        tenants.removeValue(forKey: id)
        try await persist()
    }

    public func removeForce(id: String) async throws {
        guard tenants.removeValue(forKey: id) != nil else {
            throw TenantRegistryError.notFound(id)
        }
        try await persist()
    }

    public func allTenants() async -> [TenantDefinition] {
        Array(tenants.values)
    }

    public func tenant(id: String) async -> TenantDefinition? {
        tenants[id]
    }

    public func buildIsolationPolicy() async -> any TenantIsolationPolicy {
        var pools: [TenantID: Swift.Set<HostPoolID>] = [:]
        var breakGlass: Swift.Set<TenantID> = []
        for t in tenants.values {
            pools[TenantID(t.id)] = Swift.Set(t.hostPools.map { HostPoolID($0) })
            if t.breakGlassAllowed { breakGlass.insert(TenantID(t.id)) }
        }
        return MultiTenantIsolation(tenantPools: pools, breakGlassTenants: breakGlass)
    }

    private func persist() async throws {
        guard let path = persistPath else { return }
        let data = try JSONEncoder().encode(Array(tenants.values))
        try data.write(to: URL(filePath: path))
    }
}

/// Errors raised by ``InMemoryTenantRegistry`` operations.
public enum TenantRegistryError: Error, LocalizedError, Sendable, Equatable {

    /// The requested tenant was not present in the registry.
    case notFound(String)

    /// ``InMemoryTenantRegistry/remove(id:)`` refused to delete a
    /// tenant that still has VMs attributed to it.
    ///
    /// - Parameters:
    ///   - id: Tenant identifier.
    ///   - count: Number of active VMs reported by the injected
    ///     ``TenantActiveVMCounter``.
    case tenantHasActiveVMs(id: String, count: Int)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Tenant not found: \(id)"
        case .tenantHasActiveVMs(let id, let count):
            return "Cannot remove tenant '\(id)': \(count) active VM(s) reference it."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notFound:
            return "List tenants with `GET /v1/tenants` or `spook rbac list-tenants` to confirm the id exists. Tenants are registered via `POST /v1/tenants` or SPOOKTACULAR_TENANT_CONFIG."
        case .tenantHasActiveVMs:
            return "Delete the tenant's VMs first, or call `removeForce(id:)` to orphan them (audited)."
        }
    }
}

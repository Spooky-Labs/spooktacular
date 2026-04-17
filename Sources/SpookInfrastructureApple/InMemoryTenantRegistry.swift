import Foundation
import SpookCore
import SpookApplication

/// In-memory tenant registry with optional file persistence.
///
/// Supports runtime registration and removal of tenants.
/// Optionally persists to a JSON file for restart recovery.
public actor InMemoryTenantRegistry: TenantRegistry {
    private var tenants: [String: TenantDefinition] = [:]
    private let persistPath: String?

    public init(persistPath: String? = nil) {
        self.persistPath = persistPath
        // Load from file if it exists
        if let path = persistPath,
           let data = try? Data(contentsOf: URL(filePath: path)),
           let loaded = try? JSONDecoder().decode([TenantDefinition].self, from: data) {
            for t in loaded { tenants[t.id] = t }
        }
    }

    /// Convenience: init from SpooktacularConfig
    public init(config: SpooktacularConfig, persistPath: String? = nil) {
        self.persistPath = persistPath
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

public enum TenantRegistryError: Error, LocalizedError, Sendable {
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "Tenant not found: \(id)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notFound:
            "List tenants with `GET /v1/tenants` or `spook rbac list-tenants` to confirm the id exists. Tenants are registered via `POST /v1/tenants` or SPOOK_TENANT_CONFIG."
        }
    }
}

import Foundation
import SpooktacularCore

/// Storage abstraction for ``VMIAMBinding`` records. Lets the
/// HTTP API server compose with either an in-memory store (for
/// tests) or a JSON-file store (production) without caring
/// which.
public protocol VMIAMBindingStore: Sendable {

    /// Returns the binding for `(tenant, vmName)`, or `nil` if
    /// none exists.
    func binding(vmName: String, tenant: TenantID) async throws -> VMIAMBinding?

    /// Lists all bindings for a tenant. `nil` tenant means list
    /// across all tenants (platform-admin view).
    func list(tenant: TenantID?) async throws -> [VMIAMBinding]

    /// Installs or overwrites a binding.
    func put(_ binding: VMIAMBinding) async throws

    /// Removes the binding for `(tenant, vmName)`. Idempotent —
    /// no-op if no binding exists.
    func remove(vmName: String, tenant: TenantID) async throws
}

// MARK: - In-memory store (tests)

/// An in-memory ``VMIAMBindingStore`` for tests and non-persistent
/// deployments. Thread-safe via an actor.
public actor InMemoryVMIAMBindingStore: VMIAMBindingStore {
    private var bindings: [String: VMIAMBinding] = [:]

    public init() {}

    public func binding(vmName: String, tenant: TenantID) async throws -> VMIAMBinding? {
        bindings["\(tenant.rawValue)/\(vmName)"]
    }

    public func list(tenant: TenantID?) async throws -> [VMIAMBinding] {
        if let tenant {
            return bindings.values.filter { $0.tenant == tenant }
                .sorted { $0.vmName < $1.vmName }
        }
        return bindings.values.sorted { lhs, rhs in
            lhs.tenant.rawValue == rhs.tenant.rawValue
                ? lhs.vmName < rhs.vmName
                : lhs.tenant.rawValue < rhs.tenant.rawValue
        }
    }

    public func put(_ binding: VMIAMBinding) async throws {
        bindings[binding.storeKey] = binding
    }

    public func remove(vmName: String, tenant: TenantID) async throws {
        bindings.removeValue(forKey: "\(tenant.rawValue)/\(vmName)")
    }
}

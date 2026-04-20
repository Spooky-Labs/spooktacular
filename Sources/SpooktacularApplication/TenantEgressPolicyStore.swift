import Foundation
import SpooktacularCore

/// Storage abstraction for ``TenantEgressPolicy`` records.
/// Same shape as ``VMIAMBindingStore`` so operators have one
/// mental model for per-VM configuration.
public protocol TenantEgressPolicyStore: Sendable {
    func policy(vmName: String, tenant: TenantID) async throws -> TenantEgressPolicy?
    func list(tenant: TenantID?) async throws -> [TenantEgressPolicy]
    func put(_ policy: TenantEgressPolicy) async throws
    func remove(vmName: String, tenant: TenantID) async throws
}

public actor InMemoryTenantEgressPolicyStore: TenantEgressPolicyStore {
    private var store: [String: TenantEgressPolicy] = [:]

    public init() {}

    public func policy(vmName: String, tenant: TenantID) async throws -> TenantEgressPolicy? {
        store["\(tenant.rawValue)/\(vmName)"]
    }

    public func list(tenant: TenantID?) async throws -> [TenantEgressPolicy] {
        let all = Array(store.values)
        if let tenant {
            return all.filter { $0.tenant == tenant }
                .sorted { $0.vmName < $1.vmName }
        }
        return all.sorted {
            $0.tenant.rawValue == $1.tenant.rawValue
                ? $0.vmName < $1.vmName
                : $0.tenant.rawValue < $1.tenant.rawValue
        }
    }

    public func put(_ policy: TenantEgressPolicy) async throws {
        store[policy.storeKey] = policy
    }

    public func remove(vmName: String, tenant: TenantID) async throws {
        store.removeValue(forKey: "\(tenant.rawValue)/\(vmName)")
    }
}

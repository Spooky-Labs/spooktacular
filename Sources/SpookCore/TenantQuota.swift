import Foundation

/// Per-tenant resource quotas for capacity planning and fairness.
///
/// Quotas limit the number of VMs, CPU cores, and memory a single
/// tenant can consume across a host pool. This prevents noisy
/// neighbors from starving other tenants.
///
/// ## Usage
///
/// ```swift
/// let quota = TenantQuota(maxVMs: 4, maxCPUCores: 16, maxMemoryGB: 32)
/// let usage = TenantUsage(activeVMs: 3, cpuCores: 12, memoryGB: 24)
/// quota.allows(usage: usage, adding: ResourceRequest(cpuCores: 4, memoryGB: 8))
/// // → true (3 VMs + 1 = 4 ≤ maxVMs, 12 + 4 = 16 ≤ maxCPUCores)
/// ```
public struct TenantQuota: Sendable, Codable, Equatable {
    /// Maximum number of VMs this tenant can run concurrently.
    public let maxVMs: Int

    /// Maximum total CPU cores across all VMs.
    public let maxCPUCores: Int

    /// Maximum total memory in gigabytes across all VMs.
    public let maxMemoryGB: Int

    /// Maximum number of runner pools this tenant can create.
    public let maxRunnerPools: Int

    public init(maxVMs: Int = 2, maxCPUCores: Int = 16,
                maxMemoryGB: Int = 32, maxRunnerPools: Int = 4) {
        self.maxVMs = maxVMs
        self.maxCPUCores = maxCPUCores
        self.maxMemoryGB = maxMemoryGB
        self.maxRunnerPools = maxRunnerPools
    }

    /// The default quota (matches Apple's 2-VM kernel limit on one host).
    public static let `default` = TenantQuota()

    /// An unlimited quota (for single-tenant deployments).
    public static let unlimited = TenantQuota(
        maxVMs: .max, maxCPUCores: .max,
        maxMemoryGB: .max, maxRunnerPools: .max
    )
}

/// Current resource usage for a tenant.
public struct TenantUsage: Sendable {
    public let activeVMs: Int
    public let cpuCores: Int
    public let memoryGB: Int
    public let runnerPools: Int

    public init(activeVMs: Int = 0, cpuCores: Int = 0,
                memoryGB: Int = 0, runnerPools: Int = 0) {
        self.activeVMs = activeVMs
        self.cpuCores = cpuCores
        self.memoryGB = memoryGB
        self.runnerPools = runnerPools
    }
}

/// A request to allocate resources for a new VM.
public struct ResourceRequest: Sendable {
    public let cpuCores: Int
    public let memoryGB: Int

    public init(cpuCores: Int = 4, memoryGB: Int = 8) {
        self.cpuCores = cpuCores
        self.memoryGB = memoryGB
    }
}

// MARK: - Quota Evaluation

extension TenantQuota {
    /// Checks whether the tenant can allocate the requested resources.
    ///
    /// Returns a `QuotaDecision` with either `.allowed` or `.denied`
    /// with a human-readable reason.
    public func evaluate(
        usage: TenantUsage,
        request: ResourceRequest
    ) -> QuotaDecision {
        if usage.activeVMs + 1 > maxVMs {
            return .denied("VM limit exceeded: \(usage.activeVMs)/\(maxVMs) VMs in use")
        }
        if usage.cpuCores + request.cpuCores > maxCPUCores {
            return .denied("CPU quota exceeded: \(usage.cpuCores + request.cpuCores) cores requested, \(maxCPUCores) allowed")
        }
        if usage.memoryGB + request.memoryGB > maxMemoryGB {
            return .denied("Memory quota exceeded: \(usage.memoryGB + request.memoryGB) GB requested, \(maxMemoryGB) GB allowed")
        }
        return .allowed
    }
}

/// The result of a quota evaluation.
public enum QuotaDecision: Sendable, Equatable {
    case allowed
    case denied(String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

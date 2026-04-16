import Testing
import Foundation
@testable import SpookCore

@Suite("TenantQuota")
struct TenantQuotaTests {

    @Test("Default quota allows 2 VMs")
    func defaultQuota() {
        let quota = TenantQuota.default
        let usage = TenantUsage(activeVMs: 1)
        let request = ResourceRequest(cpuCores: 4, memoryGB: 8)
        #expect(quota.evaluate(usage: usage, request: request).isAllowed)
    }

    @Test("Exceeding VM limit is denied")
    func vmLimitExceeded() {
        let quota = TenantQuota(maxVMs: 2)
        let usage = TenantUsage(activeVMs: 2)
        let request = ResourceRequest()
        let decision = quota.evaluate(usage: usage, request: request)
        #expect(!decision.isAllowed)
        if case .denied(let reason) = decision {
            #expect(reason.contains("VM limit"))
        }
    }

    @Test("Exceeding CPU quota is denied")
    func cpuQuotaExceeded() {
        let quota = TenantQuota(maxVMs: 10, maxCPUCores: 8)
        let usage = TenantUsage(activeVMs: 1, cpuCores: 6)
        let request = ResourceRequest(cpuCores: 4, memoryGB: 4)
        let decision = quota.evaluate(usage: usage, request: request)
        #expect(!decision.isAllowed)
        if case .denied(let reason) = decision {
            #expect(reason.contains("CPU"))
        }
    }

    @Test("Exceeding memory quota is denied")
    func memoryQuotaExceeded() {
        let quota = TenantQuota(maxVMs: 10, maxCPUCores: 32, maxMemoryGB: 16)
        let usage = TenantUsage(activeVMs: 0, cpuCores: 0, memoryGB: 12)
        let request = ResourceRequest(cpuCores: 4, memoryGB: 8)
        let decision = quota.evaluate(usage: usage, request: request)
        #expect(!decision.isAllowed)
        if case .denied(let reason) = decision {
            #expect(reason.contains("Memory"))
        }
    }

    @Test("Within all limits is allowed")
    func withinLimits() {
        let quota = TenantQuota(maxVMs: 4, maxCPUCores: 16, maxMemoryGB: 32)
        let usage = TenantUsage(activeVMs: 2, cpuCores: 8, memoryGB: 16)
        let request = ResourceRequest(cpuCores: 4, memoryGB: 8)
        #expect(quota.evaluate(usage: usage, request: request).isAllowed)
    }

    @Test("Unlimited quota allows everything")
    func unlimitedQuota() {
        let quota = TenantQuota.unlimited
        let usage = TenantUsage(activeVMs: 100, cpuCores: 1000, memoryGB: 10000)
        let request = ResourceRequest(cpuCores: 100, memoryGB: 100)
        #expect(quota.evaluate(usage: usage, request: request).isAllowed)
    }

    @Test("QuotaDecision equality")
    func decisionEquality() {
        #expect(QuotaDecision.allowed == QuotaDecision.allowed)
        #expect(QuotaDecision.denied("a") == QuotaDecision.denied("a"))
        #expect(QuotaDecision.allowed != QuotaDecision.denied("x"))
    }
}

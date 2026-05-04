import Testing
import Foundation
@testable import SpooktacularCore

@Suite("Tenant Quota", .tags(.security))
struct TenantQuotaTests {

    // MARK: - Quota Evaluation

    @Suite("Quota Evaluation")
    struct QuotaEvaluation {

        @Test("quota exceeded scenarios are correctly denied", arguments: [
            // (activeVMs, cpuUsed, memUsed, maxVMs, maxCPU, maxMem, reqCPU, reqMem, expectedKeyword)
            (2, 0, 0, 2, 16, 32, 4, 8, "VM limit"),
            (1, 6, 0, 10, 8, 32, 4, 8, "CPU"),
            (0, 0, 12, 10, 32, 16, 4, 8, "Memory"),
        ] as [(Int, Int, Int, Int, Int, Int, Int, Int, String)])
        func quotaExceeded(
            activeVMs: Int, cpuUsed: Int, memUsed: Int,
            maxVMs: Int, maxCPU: Int, maxMem: Int,
            reqCPU: Int, reqMem: Int,
            expectedKeyword: String
        ) {
            let quota = TenantQuota(maxVMs: maxVMs, maxCPUCores: maxCPU, maxMemoryGB: maxMem)
            let usage = TenantUsage(activeVMs: activeVMs, cpuCores: cpuUsed, memoryGB: memUsed)
            let request = ResourceRequest(cpuCores: reqCPU, memoryGB: reqMem)
            let decision = quota.evaluate(usage: usage, request: request)
            #expect(!decision.isAllowed)
            if case .denied(let reason) = decision {
                #expect(reason.contains(expectedKeyword))
            }
        }

        @Test("request within all limits is allowed")
        func withinLimits() {
            let quota = TenantQuota(maxVMs: 4, maxCPUCores: 16, maxMemoryGB: 32)
            let usage = TenantUsage(activeVMs: 2, cpuCores: 8, memoryGB: 16)
            let request = ResourceRequest(cpuCores: 4, memoryGB: 8)
            #expect(quota.evaluate(usage: usage, request: request).isAllowed)
        }

        @Test("request at exact boundary is allowed")
        func exactBoundary() {
            let quota = TenantQuota(maxVMs: 3, maxCPUCores: 12, maxMemoryGB: 24)
            let usage = TenantUsage(activeVMs: 2, cpuCores: 8, memoryGB: 16)
            let request = ResourceRequest(cpuCores: 4, memoryGB: 8)
            #expect(quota.evaluate(usage: usage, request: request).isAllowed)
        }

        @Test("unlimited quota allows any resource request")
        func unlimitedQuota() {
            let quota = TenantQuota.unlimited
            let usage = TenantUsage(activeVMs: 100, cpuCores: 1000, memoryGB: 10000)
            let request = ResourceRequest(cpuCores: 100, memoryGB: 100)
            #expect(quota.evaluate(usage: usage, request: request).isAllowed)
        }

        @Test("pending in-flight allocations count toward the VM cap")
        func pendingReservationsAreCounted() {
            // The original bug: two concurrent creations each saw
            // activeVMs=1, maxVMs=2, and both passed. With
            // `pending` reflecting the in-flight reservation, the
            // second caller sees 1 + 1 + 1 > 2 and is denied.
            let quota = TenantQuota(maxVMs: 2, maxCPUCores: 16, maxMemoryGB: 32)
            let usage = TenantUsage(activeVMs: 1)
            let request = ResourceRequest()
            let decision = quota.evaluate(usage: usage, request: request, pending: 1)
            #expect(!decision.isAllowed)
            if case .denied(let reason) = decision {
                #expect(reason.contains("pending"))
            }
        }

        @Test("pending=0 is equivalent to the old behaviour")
        func pendingZeroPreservesBehaviour() {
            let quota = TenantQuota(maxVMs: 2, maxCPUCores: 16, maxMemoryGB: 32)
            let usage = TenantUsage(activeVMs: 1)
            let request = ResourceRequest()
            let noPending = quota.evaluate(usage: usage, request: request, pending: 0)
            let implicitDefault = quota.evaluate(usage: usage, request: request)
            #expect(noPending == implicitDefault)
            #expect(noPending.isAllowed)
        }
    }

    // MARK: - Defaults

    @Suite("Defaults")
    struct Defaults {

        @Test("default quota allows up to 2 VMs")
        func defaultQuotaAllows2VMs() {
            let quota = TenantQuota.default
            let usage = TenantUsage(activeVMs: 1)
            let request = ResourceRequest(cpuCores: 4, memoryGB: 8)
            #expect(quota.evaluate(usage: usage, request: request).isAllowed)
        }

        @Test("default quota denies third VM")
        func defaultQuotaDeniesThirdVM() {
            let quota = TenantQuota.default
            let usage = TenantUsage(activeVMs: 2)
            let request = ResourceRequest()
            let decision = quota.evaluate(usage: usage, request: request)
            #expect(!decision.isAllowed)
        }

        @Test("default quota has expected limits")
        func defaultQuotaLimits() {
            let quota = TenantQuota.default
            #expect(quota.maxVMs == 2)
            #expect(quota.maxCPUCores == 16)
            #expect(quota.maxMemoryGB == 32)
            #expect(quota.maxRunnerPools == 4)
        }

        @Test("unlimited quota has Int.max for all limits")
        func unlimitedQuotaLimits() {
            let quota = TenantQuota.unlimited
            #expect(quota.maxVMs == .max)
            #expect(quota.maxCPUCores == .max)
            #expect(quota.maxMemoryGB == .max)
            #expect(quota.maxRunnerPools == .max)
        }
    }

    // MARK: - QuotaDecision

    @Suite("QuotaDecision")
    struct QuotaDecisionTests {

        @Test("allowed equals allowed")
        func allowedEquality() {
            #expect(QuotaDecision.allowed == QuotaDecision.allowed)
        }

        @Test("denied with same reason equals denied")
        func deniedEquality() {
            #expect(QuotaDecision.denied("a") == QuotaDecision.denied("a"))
        }

        @Test("allowed does not equal denied")
        func allowedNotEqualDenied() {
            #expect(QuotaDecision.allowed != QuotaDecision.denied("x"))
        }

        @Test("isAllowed returns true only for .allowed")
        func isAllowedProperty() {
            #expect(QuotaDecision.allowed.isAllowed)
            #expect(!QuotaDecision.denied("reason").isAllowed)
        }
    }
}

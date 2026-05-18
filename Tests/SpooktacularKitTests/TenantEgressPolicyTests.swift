import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

@Suite("TenantEgressPolicy", .tags(.security, .networking, .configuration))
struct TenantEgressPolicyTests {

    // MARK: - Model

    @Test("Default policy is deny-by-default with no rules")
    func defaultIsDeny() {
        let p = TenantEgressPolicy(
            tenant: TenantID("t"), vmName: "v", createdBy: "test"
        )
        #expect(p.defaultAction == .deny)
        #expect(p.rules.isEmpty)
    }

    @Test("storeKey composes tenant + vmName")
    func storeKey() {
        let p = TenantEgressPolicy(
            tenant: TenantID("team-a"), vmName: "runner-01", createdBy: "test"
        )
        #expect(p.storeKey == "team-a/runner-01")
    }

    // MARK: - EgressRule

    @Test("CIDR is recognized as CIDR")
    func ruleCIDRDetection() {
        let cidr = EgressRule(destination: "10.0.0.0/8")
        let host = EgressRule(destination: "api.github.com")
        #expect(cidr.isCIDR)
        #expect(!host.isCIDR)
    }

    // MARK: - Store

    @Test("In-memory store round-trip")
    func inMemoryRoundTrip() async throws {
        let store = InMemoryTenantEgressPolicyStore()
        let p = TenantEgressPolicy(
            tenant: TenantID("t"), vmName: "v",
            defaultAction: .deny,
            rules: [EgressRule(destination: "10.0.0.0/8", ports: [443], proto: .tcp)],
            createdBy: "alice"
        )
        try await store.put(p)
        let loaded = try await store.policy(vmName: "v", tenant: TenantID("t"))
        #expect(loaded?.rules.first?.destination == "10.0.0.0/8")
        #expect(loaded?.rules.first?.ports == [443])

        try await store.remove(vmName: "v", tenant: TenantID("t"))
        let gone = try await store.policy(vmName: "v", tenant: TenantID("t"))
        #expect(gone == nil)
    }

    @Test("JSON store persists across re-open")
    func jsonPersistence() async throws {
        let tmp = NSTemporaryDirectory() + "egress-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let writer = try JSONTenantEgressPolicyStore(configPath: tmp)
        try await writer.put(TenantEgressPolicy(
            tenant: TenantID("t"), vmName: "v",
            rules: [EgressRule(destination: "10.0.0.0/8")],
            createdBy: "alice"
        ))

        let reader = try JSONTenantEgressPolicyStore(configPath: tmp)
        let loaded = try await reader.policy(vmName: "v", tenant: TenantID("t"))
        #expect(loaded?.rules.first?.destination == "10.0.0.0/8")
    }

    // Note: prior revisions of this suite tested
    // `TenantEgressPolicyPF.generate(...)`. That enforcement
    // backend was removed when Track F' (pf) was superseded
    // by Track F'' (NEFilterDataProvider). The equivalent
    // decision-logic tests now live in
    // `SpooktacularNetworkFilterProviderTests`.
}

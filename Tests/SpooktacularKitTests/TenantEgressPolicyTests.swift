import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

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

    // MARK: - PF rule generation

    @Test("Deny-by-default generator emits block + pass rules")
    func generatePFDenyDefault() {
        let p = TenantEgressPolicy(
            tenant: TenantID("team-a"), vmName: "runner-01",
            defaultAction: .deny,
            rules: [
                EgressRule(destination: "10.0.0.0/8", ports: [443], proto: .tcp),
            ],
            createdBy: "alice"
        )
        let out = TenantEgressPolicyPF.generate(policy: p, sourceIP: "192.168.64.10")

        // Lead comment + block + pass for allowed CIDR.
        #expect(out.contains("block drop quick from 192.168.64.10 to any"))
        #expect(out.contains("pass quick from 192.168.64.10 to 10.0.0.0/8"))
        #expect(out.contains("proto tcp"))
        #expect(out.contains("port { 443 }"))
    }

    @Test("Allow-by-default generator emits pass + block rules")
    func generatePFAllowDefault() {
        let p = TenantEgressPolicy(
            tenant: TenantID("t"), vmName: "v",
            defaultAction: .allow,
            rules: [EgressRule(destination: "198.51.100.0/24")],
            createdBy: "alice"
        )
        let out = TenantEgressPolicyPF.generate(policy: p, sourceIP: "192.168.64.10")
        #expect(out.contains("pass quick from 192.168.64.10 to any"))
        #expect(out.contains("block drop quick from 192.168.64.10 to 198.51.100.0/24"))
    }

    @Test("Anchor path is tenant + vm scoped")
    func anchorScoping() {
        let p = TenantEgressPolicy(
            tenant: TenantID("team-a"), vmName: "runner-01",
            createdBy: "alice"
        )
        let out = TenantEgressPolicyPF.generate(policy: p, sourceIP: "192.168.64.10")
        #expect(out.contains("com.spooktacular.team-a.runner-01"))
    }
}

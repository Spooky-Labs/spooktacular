import Foundation
import Network
import NetworkExtension
import Testing
@testable import SpooktacularCore
@testable import SpooktacularInfrastructureApple

/// Extracts host and port strings from a `Network.NWEndpoint`
/// for use in the compiler tests. The modern `nw_endpoint_t`
/// accessors on `NENetworkRule` (`matchRemoteHostOrNetworkEndpoint`,
/// `matchLocalNetworkEndpoint`) return this enum; we
/// pattern-match `.hostPort` to recover the strings the
/// compiler wrote in.
private func hostPort(of endpoint: NWEndpoint?) -> (host: String, port: String)? {
    guard case let .hostPort(host, port) = endpoint else { return nil }
    let h: String
    switch host {
    case .name(let name, _):   h = name
    case .ipv4(let addr):      h = addr.debugDescription
    case .ipv6(let addr):      h = addr.debugDescription
    @unknown default:          return nil
    }
    return (h, String(port.rawValue))
}

/// Track F'' decision-logic coverage. `NEFilterDataProvider`
/// is hard to exercise at integration time (needs a live
/// system-extension environment) — but the policy-matching
/// core is a pure function we split out of the subclass,
/// which we can test freely.
@Suite("FilterPolicyEvaluator decision logic", .tags(.security))
struct SpooktacularNetworkFilterProviderTests {

    /// Helper — constructs a configured evaluator. Uses the
    /// standalone `FilterPolicyEvaluator` struct rather than
    /// the `SpooktacularNetworkFilterProvider` subclass,
    /// because the latter extends `NEFilterDataProvider`
    /// which traps when instantiated outside a
    /// system-extension host.
    private func provider(
        policies: [TenantEgressPolicy],
        vmBySourceIP: [String: FilterWireConfig.SourceIPMapping] = [:]
    ) -> FilterPolicyEvaluator {
        FilterPolicyEvaluator(config: FilterWireConfig(
            version: 1,
            policies: policies,
            vmBySourceIP: vmBySourceIP
        ))
    }

    private func policy(
        tenant: String,
        vm: String,
        defaultAction: TenantEgressPolicy.DefaultAction,
        rules: [EgressRule]
    ) -> TenantEgressPolicy {
        TenantEgressPolicy(
            tenant: TenantID(tenant),
            vmName: vm,
            defaultAction: defaultAction,
            rules: rules,
            createdBy: "test"
        )
    }

    @Test("Non-VM flow returns passthrough (no source-IP mapping)")
    func nonVMPassthrough() {
        let p = provider(policies: [])
        let v = p.evaluate(sourceIP: "10.0.0.1", remoteHost: "github.com", remotePort: "443")
        #expect(v == .passthrough)
    }

    @Test("VM with deny-default + no matching rule drops")
    func denyDefaultNoMatchDrops() {
        let p = provider(
            policies: [policy(
                tenant: "team-a", vm: "runner-01",
                defaultAction: .deny,
                rules: [EgressRule(destination: "github.com", ports: nil, proto: .tcp, reason: nil)]
            )],
            vmBySourceIP: [
                "192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")
            ]
        )
        let v = p.evaluate(sourceIP: "192.168.64.10", remoteHost: "evil.com", remotePort: "443")
        #expect(v == .drop)
    }

    @Test("VM with deny-default + matching hostname rule allows")
    func denyDefaultMatchingRuleAllows() {
        let p = provider(
            policies: [policy(
                tenant: "team-a", vm: "runner-01",
                defaultAction: .deny,
                rules: [EgressRule(destination: "github.com", ports: nil, proto: .tcp, reason: nil)]
            )],
            vmBySourceIP: [
                "192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")
            ]
        )
        let v = p.evaluate(sourceIP: "192.168.64.10", remoteHost: "github.com", remotePort: "443")
        #expect(v == .allow)
    }

    @Test("Hostname suffix match accepts subdomains but not sibling domains")
    func hostnameSuffixMatch() {
        let p = provider(
            policies: [policy(
                tenant: "team-a", vm: "runner-01",
                defaultAction: .deny,
                rules: [EgressRule(destination: "github.com", ports: nil, proto: .tcp, reason: nil)]
            )],
            vmBySourceIP: ["192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")]
        )

        // Real subdomain — allowed.
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "api.github.com", remotePort: "443") == .allow)
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "codeload.github.com", remotePort: "443") == .allow)

        // Evil sibling that shares the suffix but isn't a
        // real subdomain — MUST be dropped. The `.` prefix
        // on suffix match is what enforces this.
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "evilgithub.com", remotePort: "443") == .drop)
    }

    @Test("CIDR rule accepts IPs inside the prefix, rejects outside")
    func cidrMatch() {
        let p = provider(
            policies: [policy(
                tenant: "team-a", vm: "runner-01",
                defaultAction: .deny,
                rules: [EgressRule(destination: "10.0.0.0/8", ports: nil, proto: nil, reason: nil)]
            )],
            vmBySourceIP: ["192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")]
        )

        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "10.5.1.1", remotePort: "22") == .allow)
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "10.255.255.255", remotePort: "22") == .allow)
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "11.0.0.1", remotePort: "22") == .drop)
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "8.8.8.8", remotePort: "22") == .drop)
    }

    @Test("Port constraint narrows the rule — wrong port falls through to default")
    func portConstraint() {
        let p = provider(
            policies: [policy(
                tenant: "team-a", vm: "runner-01",
                defaultAction: .deny,
                rules: [EgressRule(destination: "github.com", ports: [443], proto: .tcp, reason: nil)]
            )],
            vmBySourceIP: ["192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")]
        )
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "github.com", remotePort: "443") == .allow)
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "github.com", remotePort: "80") == .drop)
    }

    @Test("Allow-default + matching rule = DENY (rule acts as denylist)")
    func allowDefaultRuleIsDenylist() {
        let p = provider(
            policies: [policy(
                tenant: "team-a", vm: "runner-01",
                defaultAction: .allow,
                rules: [EgressRule(destination: "evil.com", ports: nil, proto: nil, reason: nil)]
            )],
            vmBySourceIP: ["192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")]
        )
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "evil.com", remotePort: "443") == .drop)
        #expect(p.evaluate(sourceIP: "192.168.64.10", remoteHost: "github.com", remotePort: "443") == .allow)
    }

    @Test("VM with mapping but no matching policy = passthrough (orphan)")
    func orphanMapping() {
        let p = provider(
            policies: [],
            vmBySourceIP: ["192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")]
        )
        // No policy for team-a/runner-01 even though we have
        // an IP mapping — treat as non-VM to avoid
        // accidentally denying all traffic just because a
        // stale mapping is present.
        let v = p.evaluate(sourceIP: "192.168.64.10", remoteHost: "github.com", remotePort: "443")
        #expect(v == .passthrough)
    }
}

@Suite("NEFilterConfigurator wire format", .tags(.security))
struct NEFilterConfiguratorWireFormatTests {

    @Test("FilterWireConfig round-trips — version, policies, source-IP map")
    func filterWireConfigRoundTrip() throws {
        let original = FilterWireConfig(
            version: 1,
            policies: [
                TenantEgressPolicy(
                    tenant: TenantID("team-a"),
                    vmName: "runner-01",
                    defaultAction: .deny,
                    rules: [
                        EgressRule(destination: "github.com", ports: [443], proto: .tcp, reason: "ci")
                    ],
                    createdBy: "test"
                )
            ],
            vmBySourceIP: [
                "192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        // Idempotence check — `Date` ISO-8601 encoding
        // truncates sub-seconds, so `original == roundtripped`
        // isn't guaranteed even when the wire format is
        // correct. Encoding the already-decoded value and
        // comparing the BYTES proves the format is stable
        // across arbitrarily-many round-trips.
        let data = try encoder.encode(original)
        let decoded = try FilterWireConfig.decode(from: data)
        let reencoded = try encoder.encode(decoded)
        #expect(data == reencoded)

        // Also spot-check that structural fields are
        // preserved (the date fuzziness above only affects
        // the `createdAt` timestamp).
        #expect(decoded.version == original.version)
        #expect(decoded.policies.count == original.policies.count)
        #expect(decoded.policies.first?.tenant == original.policies.first?.tenant)
        #expect(decoded.policies.first?.rules == original.policies.first?.rules)
        #expect(decoded.vmBySourceIP == original.vmBySourceIP)
    }

    @Test("Version field must equal 1 for decode to treat policies as valid")
    func schemaVersionPinned() {
        // Documents the invariant. Bumping `version` is a
        // breaking change the extension explicitly rejects
        // (falling back to pass-through) so older extensions
        // don't silently mis-parse newer host blobs.
        let config = FilterWireConfig(version: 1, policies: [], vmBySourceIP: [:])
        #expect(config.version == 1)
    }

    @Test("Compiler: CIDR rule becomes a kernel fast-path NEFilterRule with the right endpoints")
    func compileCIDRRuleProducesKernelFastPath() {
        let config = FilterWireConfig(
            version: 1,
            policies: [
                TenantEgressPolicy(
                    tenant: TenantID("team-a"),
                    vmName: "runner-01",
                    defaultAction: .deny,
                    rules: [
                        EgressRule(destination: "10.0.0.0/8", ports: [443], proto: .tcp, reason: nil)
                    ],
                    createdBy: "test"
                )
            ],
            vmBySourceIP: [
                "192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")
            ]
        )
        let settings = FilterSettingsCompiler(config: config).compile()

        #expect(settings.defaultAction == .filterData)
        #expect(settings.rules.count == 1)

        let filterRule = settings.rules[0]
        // deny-default + match → allow (allowlist semantics)
        #expect(filterRule.action == .allow)

        let nr = filterRule.networkRule
        #expect(nr.matchProtocol == .TCP)
        #expect(nr.matchDirection == .outbound)
        #expect(nr.matchRemotePrefix == 8)
        #expect(nr.matchLocalPrefix == 32)
        // Read the endpoint data via the modern nw_endpoint_t
        // accessor — the legacy `matchRemoteEndpoint` /
        // `matchLocalNetwork` return `NWHostEndpoint`, which is
        // hidden in Swift 6.
        let remote = hostPort(of: nr.matchRemoteHostOrNetworkEndpoint)
        let local = hostPort(of: nr.matchLocalNetworkEndpoint)
        #expect(remote?.host == "10.0.0.0")
        #expect(remote?.port == "443")
        #expect(local?.host == "192.168.64.10")
    }

    @Test("Compiler: hostname rule is skipped (stays in handleNewFlow)")
    func compilerSkipsHostnameRules() {
        let config = FilterWireConfig(
            version: 1,
            policies: [
                TenantEgressPolicy(
                    tenant: TenantID("team-a"),
                    vmName: "runner-01",
                    defaultAction: .deny,
                    rules: [
                        EgressRule(destination: "github.com", ports: [443], proto: .tcp, reason: nil),
                        EgressRule(destination: "10.0.0.0/8", ports: nil, proto: nil, reason: nil)
                    ],
                    createdBy: "test"
                )
            ],
            vmBySourceIP: ["192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")]
        )
        let settings = FilterSettingsCompiler(config: config).compile()
        // One rule (the CIDR), not two — hostname is skipped.
        #expect(settings.rules.count == 1)
        #expect(hostPort(of: settings.rules[0].networkRule.matchRemoteHostOrNetworkEndpoint)?.host == "10.0.0.0")
    }

    @Test("Compiler: allow-default policy emits .drop actions (denylist semantics)")
    func compilerAllowDefaultMakesDropRules() {
        let config = FilterWireConfig(
            version: 1,
            policies: [
                TenantEgressPolicy(
                    tenant: TenantID("team-a"),
                    vmName: "runner-01",
                    defaultAction: .allow,
                    rules: [
                        EgressRule(destination: "10.0.0.0/8", ports: nil, proto: nil, reason: nil)
                    ],
                    createdBy: "test"
                )
            ],
            vmBySourceIP: ["192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")]
        )
        let settings = FilterSettingsCompiler(config: config).compile()
        #expect(settings.rules.count == 1)
        #expect(settings.rules[0].action == .drop)
    }

    @Test("Compiler: multi-port rule expands to one NEFilterRule per port")
    func compilerExpandsMultiPort() {
        let config = FilterWireConfig(
            version: 1,
            policies: [
                TenantEgressPolicy(
                    tenant: TenantID("team-a"),
                    vmName: "runner-01",
                    defaultAction: .deny,
                    rules: [
                        EgressRule(destination: "10.0.0.0/8", ports: [80, 443], proto: .tcp, reason: nil)
                    ],
                    createdBy: "test"
                )
            ],
            vmBySourceIP: ["192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")]
        )
        let settings = FilterSettingsCompiler(config: config).compile()
        #expect(settings.rules.count == 2)
        let ports = settings.rules
            .compactMap { hostPort(of: $0.networkRule.matchRemoteHostOrNetworkEndpoint)?.port }
            .sorted()
        #expect(ports == ["443", "80"])
    }

    @Test("Compiler: VM with no source-IP mapping produces no fast-path rules")
    func compilerSkipsUnmappedVM() {
        let config = FilterWireConfig(
            version: 1,
            policies: [
                TenantEgressPolicy(
                    tenant: TenantID("team-a"),
                    vmName: "ghost-vm",
                    defaultAction: .deny,
                    rules: [EgressRule(destination: "10.0.0.0/8", ports: nil, proto: nil, reason: nil)],
                    createdBy: "test"
                )
            ],
            vmBySourceIP: [:]  // no mapping
        )
        let settings = FilterSettingsCompiler(config: config).compile()
        #expect(settings.rules.isEmpty)
    }

    @Test("Host → native dict → extension decode round-trip")
    func nativeDictBridgeRoundTrip() throws {
        // Mirrors the real wire path:
        //   Host:  Codable → JSONEncoder → JSONSerialization.jsonObject  → [String: Any]
        //   Ext.:  [String: Any] → JSONSerialization.data → JSONDecoder → Codable
        //
        // `NEFilterProviderConfiguration.vendorConfiguration`
        // is the handoff point; this test substitutes a plain
        // `[String: Any]` for it and verifies the extension
        // rebuilds the exact `FilterWireConfig` the host sent.
        let original = FilterWireConfig(
            version: 1,
            policies: [
                TenantEgressPolicy(
                    tenant: TenantID("team-a"),
                    vmName: "runner-01",
                    defaultAction: .deny,
                    rules: [
                        EgressRule(destination: "github.com", ports: [443], proto: .tcp, reason: "ci"),
                        EgressRule(destination: "10.0.0.0/8", ports: nil, proto: nil, reason: nil)
                    ],
                    createdBy: "test"
                )
            ],
            vmBySourceIP: [
                "192.168.64.10": .init(tenant: "team-a", vmName: "runner-01")
            ]
        )

        // Host side — same steps as `NEFilterConfigurator.serialize(...)`.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encodedBlob = try encoder.encode(original)
        let nativeDict = try #require(
            try JSONSerialization.jsonObject(with: encodedBlob, options: []) as? [String: Any],
            "host-side serialize must yield [String: Any]"
        )

        // Sanity check — the dict is property-list-compatible
        // (what `vendorConfiguration` requires).
        #expect(JSONSerialization.isValidJSONObject(nativeDict))

        // Extension side — same steps as
        // `SpooktacularNetworkFilterProvider.loadConfig()`.
        let data = try JSONSerialization.data(withJSONObject: nativeDict, options: [.sortedKeys])
        let decoded = try FilterWireConfig.decode(from: data)

        #expect(decoded.version == 1)
        #expect(decoded.policies.count == 1)
        #expect(decoded.policies.first?.tenant == original.policies.first?.tenant)
        #expect(decoded.policies.first?.rules == original.policies.first?.rules)
        #expect(decoded.vmBySourceIP == original.vmBySourceIP)
    }
}

import Foundation
import Network
import NetworkExtension
import SpooktacularCore

/// Translates a ``FilterWireConfig`` into an
/// ``NEFilterSettings`` that the kernel can evaluate for us
/// — letting matching flows be allow/dropped *without* a
/// round-trip to ``SpooktacularNetworkFilterProvider/handleNewFlow(_:)``.
///
/// ## Why this exists
///
/// `NEFilterDataProvider` has two decision-making surfaces:
///
/// - **Rule-based, typed:** `apply(NEFilterSettings?, completionHandler:)`
///   installs rules keyed on `NENetworkRule` matchers
///   (destination/source endpoint, CIDR prefix, protocol,
///   direction). The kernel evaluates these and only calls
///   `handleNewFlow` for flows that don't match any rule.
/// - **Callback-based, flexible:** `handleNewFlow(_:)` —
///   custom Swift per-flow evaluation, required for anything
///   that can't be expressed as an `NENetworkRule` (hostname
///   suffix matching, tenant-aware defaults, etc.).
///
/// This compiler translates the subset of our policy that
/// maps to `NENetworkRule` (IP + CIDR + port + protocol
/// matches) into the fast-path, and leaves everything else
/// (hostname suffixes, per-VM default actions) in the
/// callback. Net effect: kernel-level match for the common
/// case, zero behavior change for the uncommon one.
///
/// ## Apple references
///
/// - [`NEFilterDataProvider.apply(_:completionHandler:)`](https://developer.apple.com/documentation/networkextension/nefilterdataprovider/apply(_:completionhandler:))
/// - [`NEFilterSettings`](https://developer.apple.com/documentation/networkextension/nefiltersettings)
/// - [`NEFilterRule`](https://developer.apple.com/documentation/networkextension/nefilterrule)
/// - [`NENetworkRule`](https://developer.apple.com/documentation/networkextension/nenetworkrule)
///
/// ## Semantics
///
/// Each rule is compiled with an `NEFilterAction`:
///
/// | Policy default | Rule match action | Rationale |
/// |---|---|---|
/// | `.deny` (allowlist) | `.allow` | Matching a rule allows the flow; non-matches fall through to `handleNewFlow` which applies the deny-default. |
/// | `.allow` (denylist) | `.drop` | Matching a rule denies the flow; non-matches fall through to `handleNewFlow` which applies the allow-default. |
///
/// The settings' overall `defaultAction` is
/// ``NEFilterAction/filterData`` — "call `handleNewFlow` for
/// anything not pre-matched" — so the VM default action logic
/// (including the orphan-IP passthrough) stays exactly as
/// before.
public struct FilterSettingsCompiler: Sendable {

    /// The policy set + VM-IP mapping to compile.
    public let config: FilterWireConfig

    public init(config: FilterWireConfig) {
        self.config = config
    }

    /// Builds an `NEFilterSettings` covering every CIDR / IP
    /// rule in the config. Hostname rules are skipped — they
    /// keep getting decided in ``SpooktacularNetworkFilterProvider/handleNewFlow(_:)``.
    public func compile() -> NEFilterSettings {
        var rules: [NEFilterRule] = []
        for policy in config.policies {
            guard let sourceIP = sourceIP(
                tenant: policy.tenant.rawValue,
                vmName: policy.vmName
            ) else {
                // VM has no resolved source IP — nothing we
                // can fast-path. Its traffic still gets
                // decided in handleNewFlow (if at all).
                continue
            }

            // deny-default: rules are allowlist → match = allow
            // allow-default: rules are denylist → match = drop
            let matchAction: NEFilterAction =
                policy.defaultAction == .deny ? .allow : .drop

            for egressRule in policy.rules {
                rules.append(contentsOf: filterRules(
                    for: egressRule,
                    sourceIP: sourceIP,
                    action: matchAction
                ))
            }
        }
        return NEFilterSettings(rules: rules, defaultAction: .filterData)
    }

    // MARK: - Helpers

    /// Reverse-lookup: given a tenant + VM name, return the
    /// source IP the host side told us about in the
    /// `vmBySourceIP` map.
    private func sourceIP(tenant: String, vmName: String) -> String? {
        for (ip, mapping) in config.vmBySourceIP
            where mapping.tenant == tenant && mapping.vmName == vmName {
            return ip
        }
        return nil
    }

    /// Translates one ``EgressRule`` into zero or more
    /// `NEFilterRule`s. Returns `[]` for hostname rules
    /// (which can't be expressed as `NENetworkRule`) — those
    /// stay in the evaluator. A rule with N ports produces N
    /// `NEFilterRule`s; an unportscoped rule produces one with
    /// a wildcard port (`"0"`).
    private func filterRules(
        for rule: EgressRule,
        sourceIP: String,
        action: NEFilterAction
    ) -> [NEFilterRule] {
        guard let (address, prefix) = Self.parseAddressAndPrefix(rule.destination) else {
            // Hostname rules like "github.com" or
            // ".github.com" can't be matched by NENetworkRule
            // (which only matches IP / CIDR). Skip — they
            // remain handled in handleNewFlow.
            return []
        }

        // VM source IP is always a specific host (not a
        // wildcard), so per NEFilterSettings constraints a
        // port of "0" is fine. Prefix length 32 = /32 exact
        // host match on the local side.
        //
        // Apple's legacy `NWHostEndpoint` is hidden in Swift 6
        // (per the NetworkExtension/NWHostEndpoint.h header
        // "DEPRECATION NOTICE"); the modern bridge is
        // `Network.NWEndpoint.hostPort(...)`, which
        // Obj-C–bridges to `nw_endpoint_t` — the type the
        // `remoteNetworkEndpoint:` / `localNetworkEndpoint:`
        // initializer on `NENetworkRule` actually takes.
        let localEP = Self.endpoint(host: sourceIP, port: "0")
        let egressProto = rule.proto

        let ports: [String] = rule.ports?.map(String.init) ?? ["0"]
        return ports.map { port in
            let remoteEP = Self.endpoint(host: address, port: port)
            // Inline switch so Swift infers the
            // `NENetworkRule.Protocol` type from the init's
            // `protocol:` parameter — avoids naming a type
            // that collides with the Swift `Protocol`
            // keyword (which would otherwise need backticks).
            let networkRule = NENetworkRule(
                remoteNetworkEndpoint: remoteEP,
                remotePrefix: prefix,
                localNetworkEndpoint: localEP,
                localPrefix: 32,
                protocol: {
                    switch egressProto {
                    case .tcp: return .TCP
                    case .udp: return .UDP
                    case .any, .none: return .any
                    }
                }(),
                direction: .outbound
            )
            return NEFilterRule(networkRule: networkRule, action: action)
        }
    }

    /// Builds a `Network.NWEndpoint.hostPort(...)` suitable
    /// for the `nw_endpoint_t`-bridged `NENetworkRule`
    /// initializers. `Port.init(_:)` is optional — it returns
    /// `nil` on parse failure — but we only ever feed it
    /// `"0"` or the stringified Int from `EgressRule.ports`,
    /// both of which always parse. The fallback to `.any`
    /// covers the type-system escape hatch without adding a
    /// runtime precondition.
    private static func endpoint(host: String, port: String) -> NWEndpoint {
        .hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(port) ?? .any
        )
    }

    /// Parses an IPv4 host (`"10.5.1.1"` → `("10.5.1.1", 32)`)
    /// or CIDR (`"10.0.0.0/8"` → `("10.0.0.0", 8)`). Returns
    /// `nil` for anything that doesn't parse as an IP literal —
    /// hostnames like `"github.com"` fall through.
    ///
    /// IPv6 is deliberately not handled yet — our `EgressRule`
    /// model + `FilterPolicyEvaluator`'s `IPAddress` helper
    /// are IPv4-only today, and the fast-path should stay
    /// consistent with the callback path.
    static func parseAddressAndPrefix(_ destination: String) -> (String, Int)? {
        if let slashIdx = destination.firstIndex(of: "/") {
            let addr = String(destination[..<slashIdx])
            let prefixStr = destination[destination.index(after: slashIdx)...]
            guard isIPv4(addr),
                  let prefix = Int(prefixStr),
                  (0...32).contains(prefix) else { return nil }
            return (addr, prefix)
        }
        if isIPv4(destination) {
            return (destination, 32)
        }
        return nil
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}

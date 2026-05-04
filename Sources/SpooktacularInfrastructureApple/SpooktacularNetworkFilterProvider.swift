import Foundation
import Network
import NetworkExtension
import os
import SpooktacularCore

/// Pure-data decision engine for the Spooktacular network
/// filter.
///
/// Kept **outside** the `NEFilterDataProvider` subclass so
/// unit tests never have to instantiate that class — which
/// expects to be hosted inside a system extension and traps
/// when constructed in a plain test process.
///
/// The provider class delegates every matching decision
/// here; the only thing it does itself is translate
/// `NEFilterFlow` / `nw_endpoint_t` values into the
/// evaluator's string inputs and the verdict back into
/// `NEFilterNewFlowVerdict`.
public struct FilterPolicyEvaluator: Sendable {

    public enum Verdict: Sendable, Equatable {
        /// VM flow that matches an egress rule allowing it.
        case allow
        /// VM flow that no rule allows (and default is deny).
        case drop
        /// Not a VM flow — we don't filter.
        case passthrough
    }

    public let config: FilterWireConfig

    public init(config: FilterWireConfig) {
        self.config = config
    }

    /// Decision logic in its pure form. `sourceIP` is the
    /// flow's local endpoint (the VM's NAT-assigned IP);
    /// `remoteHost` / `remotePort` describe the destination
    /// (both are optional because `nw_endpoint_t` can be a
    /// shape we can't destructure, e.g. `.unix`).
    public func evaluate(
        sourceIP: String,
        remoteHost: String?,
        remotePort: String?
    ) -> Verdict {
        guard let mapping = config.vmBySourceIP[sourceIP] else {
            return .passthrough
        }
        guard let policy = config.policies.first(where: {
            $0.tenant.rawValue == mapping.tenant && $0.vmName == mapping.vmName
        }) else {
            // VM has an IP mapping but no policy → treat as
            // non-VM flow (no active policy = no filtering).
            return .passthrough
        }

        let ruleMatch = policy.rules.first {
            $0.matches(remoteHost: remoteHost, remotePort: remotePort)
        }

        switch (policy.defaultAction, ruleMatch) {
        case (.deny, .some):    return .allow
        case (.deny, .none):    return .drop
        case (.allow, .some):   return .drop   // explicit rules in allow-default act as denylist
        case (.allow, .none):   return .allow
        }
    }
}

/// The `NEFilterDataProvider` subclass that becomes the
/// Spooktacular system extension in Phase B.
///
/// ## What this actually does
///
/// When `NEFilterManager` activates the filter, the system
/// spins up this class inside the extension bundle (out of
/// process from the main app). For every new TCP/UDP flow
/// originating on this Mac, the kernel calls
/// ``handleNewFlow(_:)``. We match the flow's source IP
/// against `FilterWireConfig.vmBySourceIP` — if it's a
/// VM flow, we look up that VM's policy and decide `.allow`
/// or `.drop`. Non-VM flows pass through untouched.
///
/// The extension runs with the
/// `com.apple.developer.networking.networkextension`
/// entitlement (subtype `content-filter-provider`) and has
/// read-only access to the policy via the
/// `NEFilterProviderConfiguration.vendorConfiguration`
/// dictionary the host wrote.
///
/// ## Apple API references
///
/// - [`NEFilterDataProvider`](https://developer.apple.com/documentation/networkextension/nefilterdataprovider)
/// - [`NEFilterFlow`](https://developer.apple.com/documentation/networkextension/nefilterflow)
/// - [`NEFilterNewFlowVerdict`](https://developer.apple.com/documentation/networkextension/nefilternewflowverdict)
/// - [`startFilter(completionHandler:)`](https://developer.apple.com/documentation/networkextension/nefilterdataprovider/2778185-startfilter)
/// - [`stopFilter(with:completionHandler:)`](https://developer.apple.com/documentation/networkextension/nefilterdataprovider/2778184-stopfilter)
///
/// ## Phase A vs B
///
/// Phase A (this turn): the class is defined and unit-
/// testable. It compiles as a regular library target.
/// Phase B (follow-up): `project.yml` gains a new target
/// whose product is a `.systemextension` bundle, signed
/// with the NE content-filter entitlement. The `principal
/// class` is this one; the main app calls
/// `OSSystemExtensionRequest.activationRequest` to install
/// it.
open class SpooktacularNetworkFilterProvider: NEFilterDataProvider {

    private static let log = Logger(
        subsystem: "com.spooktacular.app.NetworkFilter",
        category: "network-filter"
    )

    /// In-memory copy of the policy set. Refreshed on
    /// `startFilter` and on any `handleReport(_:)` /
    /// `NEFilterManager.saveToPreferences()` round-trip.
    private var config: FilterWireConfig = FilterWireConfig(
        version: 1,
        policies: [],
        vmBySourceIP: [:]
    )

    /// Apple's async `startFilter()` — the Swift-6 idiomatic
    /// override avoids capturing the caller's non-Sendable
    /// completion handler inside a `@Sendable` closure (which
    /// is what the legacy `completionHandler:` override did, and
    /// what the compiler correctly flagged as a race risk). The
    /// async variant is documented at
    /// https://developer.apple.com/documentation/networkextension/nefilterprovider/startfilter()
    public override func startFilter() async throws {
        loadConfig()
        // Compile IP/CIDR rules into NEFilterSettings so the
        // kernel can short-circuit matching flows without
        // calling handleNewFlow. Hostname rules and per-VM
        // default actions still flow through handleNewFlow
        // via defaultAction = .filterData.
        let settings = FilterSettingsCompiler(config: self.config).compile()
        Self.log.notice(
            """
            Filter started — \(self.config.policies.count) policy(ies), \
            \(self.config.vmBySourceIP.count) VM IP mapping(s), \
            \(settings.rules.count) kernel fast-path rule(s)
            """
        )
        do {
            try await apply(settings)
        } catch {
            Self.log.error(
                "apply(settings:) failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    public override func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Self.log.notice(
            "Filter stopped (reason: \(String(describing: reason), privacy: .public))"
        )
        completionHandler()
    }

    public override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let verdict: FilterPolicyEvaluator.Verdict = evaluate(flow: flow)
        switch verdict {
        case .drop:
            Self.log.info(
                "DROP \(flow.description, privacy: .public)"
            )
            return .drop()
        case .allow:
            // `.allow()` approves the flow at the new-flow
            // stage and tells the kernel it never needs to
            // call our `handleInbound/OutboundData` for this
            // flow — saves us from the data-phase callbacks
            // entirely for approved flows.
            return .allow()
        case .passthrough:
            // Non-VM flow — let it through without inspecting
            // its data. Saves CPU on the 95% case where we
            // have nothing to say about the flow.
            return .allow()
        }
    }

    // Apple's `NEFilterDataProvider` subclassing notes list
    // six override methods. `handleNewFlow(_:)` is our
    // real enforcement point — if we `.allow()` a flow
    // there, the data-phase methods don't fire for it.
    // The overrides below exist to supply Apple-documented
    // defaults for any flow where the system decides to
    // exercise the data phase anyway (e.g., if a future
    // rule change requires re-evaluation at byte arrival).

    public override func handleInboundData(
        from flow: NEFilterFlow,
        readBytesStartOffset offset: Int,
        readBytes: Data
    ) -> NEFilterDataVerdict {
        // No deep-packet inspection — IP/hostname filtering
        // is fully decided at `handleNewFlow`. Returning
        // `.allow()` tells the kernel "do not send further
        // inbound data callbacks for this flow."
        return .allow()
    }

    public override func handleOutboundData(
        from flow: NEFilterFlow,
        readBytesStartOffset offset: Int,
        readBytes: Data
    ) -> NEFilterDataVerdict {
        return .allow()
    }

    public override func handleInboundDataComplete(
        for flow: NEFilterFlow
    ) -> NEFilterDataVerdict {
        return .allow()
    }

    public override func handleOutboundDataComplete(
        for flow: NEFilterFlow
    ) -> NEFilterDataVerdict {
        return .allow()
    }

    // `handleRulesChanged()` is iOS-only on macOS
    // availability tables — the filter reloads its config
    // via `startFilter` when the system re-initializes it
    // after a `NEFilterManager.saveToPreferences()` call.
    // No override needed.

    // `handleRemediation(for:)` is iOS-only — the
    // `NEFilterRemediationVerdict` type isn't available on
    // macOS, so we don't override it.

    // MARK: - Policy evaluation

    /// Decision-logic delegate. Kept as a standalone struct
    /// so unit tests can exercise matching without
    /// instantiating `NEFilterDataProvider` itself — that
    /// base class expects to run inside the system-
    /// extension host, and constructing one in a plain test
    /// process traps.
    func evaluate(flow: NEFilterFlow) -> FilterPolicyEvaluator.Verdict {
        guard let socket = flow as? NEFilterSocketFlow,
              let local = socket.localFlowEndpoint,
              let remote = socket.remoteFlowEndpoint else {
            return .passthrough
        }
        let sourceIP = hostString(from: local)
        let remoteHost = hostString(from: remote)
        let remotePort = portString(from: remote)
        guard let sourceIP else { return .passthrough }
        return FilterPolicyEvaluator(config: config).evaluate(
            sourceIP: sourceIP,
            remoteHost: remoteHost,
            remotePort: remotePort
        )
    }

    // MARK: - nw_endpoint helpers

    /// Extracts the host string from an `nw_endpoint_t`.
    /// Apple's `NWEndpoint` is imported in Swift with named
    /// cases; we match `.hostPort` which is the shape
    /// sockets produce.
    private func hostString(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .name(let name, _):
                return name
            case .ipv4(let address):
                return address.debugDescription
            case .ipv6(let address):
                return address.debugDescription
            @unknown default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Extracts the port string from an `nw_endpoint_t`.
    private func portString(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(_, let port):
            return String(port.rawValue)
        default:
            return nil
        }
    }

    // MARK: - Config loading

    private func loadConfig() {
        // `NEFilterProvider.filterConfiguration` returns the
        // configuration installed by the host side (see
        // [NEFilterProvider docs](https://developer.apple.com/documentation/networkextension/nefilterprovider/filterconfiguration)).
        // `vendorConfiguration` is a `[String: Any]?` dict the
        // host populates via `JSONSerialization.jsonObject(with:)`
        // — native Foundation types (`NSDictionary`, `NSArray`,
        // `NSString`, `NSNumber`) straight from the JSON
        // produced by `JSONEncoder`. We do the symmetric bridge
        // back: `JSONSerialization.data(withJSONObject:)` →
        // `JSONDecoder.decode`. This keeps the wire format
        // `defaults read`-inspectable on the host while giving
        // the extension a strongly-typed `FilterWireConfig`.
        guard let dict = self.filterConfiguration.vendorConfiguration else {
            Self.log.warning("Filter started with no vendorConfiguration — defaulting to pass-through")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            let decoded = try FilterWireConfig.decode(from: data)
            guard decoded.version == 1 else {
                Self.log.error(
                    "Unsupported policy schema version \(decoded.version) — defaulting to pass-through"
                )
                return
            }
            self.config = decoded
        } catch {
            Self.log.error(
                "Failed to decode policy blob: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Test seam — unit tests inject a config directly
    /// rather than constructing a live `NEFilterProvider`
    /// environment.
    func _setConfigForTesting(_ config: FilterWireConfig) {
        self.config = config
    }
}

// MARK: - Rule matching

extension EgressRule {
    /// Returns `true` if `(remoteHost, remotePort)` matches
    /// this rule's destination + port constraint.
    ///
    /// `remoteHost` comes from `NEFilterSocketFlow.remoteFlowEndpoint`
    /// — may be a hostname (pre-DNS-resolution, if the guest
    /// OS hands NE the original name) or an IPv4/IPv6
    /// literal (post-resolution). We try both match paths in
    /// order: CIDR if the rule destination parses as a
    /// prefix and the host parses as an IP; hostname suffix
    /// match otherwise.
    func matches(remoteHost: String?, remotePort: String?) -> Bool {
        guard let remoteHost else { return false }

        // Port constraint.
        if let ports, !ports.isEmpty {
            guard let portString = remotePort, let flowPort = Int(portString),
                  ports.contains(flowPort) else {
                return false
            }
        }

        // CIDR if destination parses as a prefix and host is
        // an IP.
        if let cidr = CIDR(destination), let ip = IPAddress(remoteHost) {
            return cidr.contains(ip)
        }

        // Hostname suffix match. The leading `.` prevents
        // `evilgithub.com` matching a rule for `github.com`.
        if destination == remoteHost { return true }
        return remoteHost.hasSuffix("." + destination)
    }
}

// MARK: - Lightweight CIDR / IP helpers

/// IPv4/IPv6 parser shared by the rule matcher. Kept
/// minimal — we only need CIDR containment, not broader
/// arithmetic.
private struct IPAddress {
    let v4: (UInt8, UInt8, UInt8, UInt8)?
    init?(_ string: String) {
        // Fast path: IPv4 dotted quad.
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for p in parts {
            guard let o = UInt8(p) else { return nil }
            octets.append(o)
        }
        self.v4 = (octets[0], octets[1], octets[2], octets[3])
    }
}

private struct CIDR {
    let base: (UInt8, UInt8, UInt8, UInt8)
    let prefixLen: Int
    init?(_ string: String) {
        let parts = string.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 0, prefix <= 32,
              let ip = IPAddress(String(parts[0])),
              let v4 = ip.v4 else {
            return nil
        }
        self.base = v4
        self.prefixLen = prefix
    }
    func contains(_ ip: IPAddress) -> Bool {
        guard let v4 = ip.v4 else { return false }
        let baseInt = (UInt32(base.0) << 24) | (UInt32(base.1) << 16)
                    | (UInt32(base.2) << 8)  | UInt32(base.3)
        let targetInt = (UInt32(v4.0) << 24) | (UInt32(v4.1) << 16)
                      | (UInt32(v4.2) << 8)  | UInt32(v4.3)
        let mask: UInt32 = prefixLen == 0 ? 0 : UInt32.max << (32 - prefixLen)
        return (baseInt & mask) == (targetInt & mask)
    }
}

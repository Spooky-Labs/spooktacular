import Foundation

/// An operator-authored egress-network policy for a VM.
///
/// Network egress from a macOS guest VM runs through the host's
/// NAT by default — which means the guest can reach anything
/// the host can reach. Enterprise tenants routinely need the
/// opposite: a deny-by-default posture with an explicit
/// allowlist of destinations, both for compliance (data-
/// exfiltration risk) and for defense-in-depth (compromised
/// CI job can't phone home).
///
/// ## Model
///
/// - Policies are **per-VM, scoped by tenant**. Same pattern as
///   ``VMIAMBinding``. The key is `(tenant, vmName)`.
/// - The policy declares a `defaultAction` (almost always
///   `.deny`) plus a list of ``EgressRule``s permitted to
///   override it.
/// - Each rule names a destination CIDR **or** a hostname plus
///   optional port / protocol constraints. Hostname rules are
///   documented as "generator-side DNS resolution" — the PF
///   generator expands them at apply time.
///
/// ## Enforcement
///
/// This type is the **policy model + serializer**; enforcement
/// runs through generated macOS PF (packet filter) rules the
/// operator applies with `pfctl -a com.spooktacular -f <file>`.
/// Automatic PF application at VM start is a deliberate follow-
/// up: wiring `pfctl` into the VM start path requires root on
/// the host, so the first ship operates the one-commit policy
/// lifecycle without that risk.
public struct TenantEgressPolicy: Sendable, Codable, Equatable {

    public enum DefaultAction: String, Sendable, Codable {
        /// Everything NOT matched by a rule is **denied**. This
        /// is the recommended posture for multi-tenant fleets.
        case deny
        /// Everything NOT matched by a rule is **allowed**. Use
        /// for exception-list style policies where only a few
        /// destinations are explicitly forbidden.
        case allow
    }

    public let tenant: TenantID
    public let vmName: String
    public let defaultAction: DefaultAction
    public let rules: [EgressRule]
    public let createdAt: Date
    public let createdBy: String

    public init(
        tenant: TenantID,
        vmName: String,
        defaultAction: DefaultAction = .deny,
        rules: [EgressRule] = [],
        createdAt: Date = Date(),
        createdBy: String
    ) {
        self.tenant = tenant
        self.vmName = vmName
        self.defaultAction = defaultAction
        self.rules = rules
        self.createdAt = createdAt
        self.createdBy = createdBy
    }

    /// Composite key for store lookup.
    public var storeKey: String { "\(tenant.rawValue)/\(vmName)" }
}

/// A single destination that, when combined with its
/// ``TenantEgressPolicy/defaultAction`` counterpart, permits or
/// denies outbound traffic from the tenant's VM.
public struct EgressRule: Sendable, Codable, Equatable {

    // The trailing underscore is deliberate — `Protocol` is a
    // Swift keyword, and this enum is the *network* protocol in
    // a pf(8) rule. Renaming to `NetworkProtocol` would read
    // fine at the declaration site but hurt the call-site noun
    // (`rule.proto: .tcp` is clearer than `rule.networkProto`).
    // swiftlint:disable:next type_name
    public enum Protocol_: String, Sendable, Codable {
        case tcp, udp, any
    }

    /// Destination. Either a CIDR (`"10.0.0.0/8"`, `"192.168.1.0/24"`,
    /// `"203.0.113.5/32"`) or a DNS hostname (`"api.github.com"`).
    /// Hostnames are resolved by the generator at PF-rule emit
    /// time, so DNS-changing destinations require re-generating
    /// rules.
    public let destination: String

    /// Ports allowed on this destination. `nil` means all ports.
    public let ports: [Int]?

    /// Protocol filter. `nil` = `.any`.
    public let proto: Protocol_?

    /// Human-readable rationale surfaced in audit records +
    /// generated PF comments. Not functional, strongly
    /// recommended.
    public let reason: String?

    public init(
        destination: String,
        ports: [Int]? = nil,
        proto: Protocol_? = .any,
        reason: String? = nil
    ) {
        self.destination = destination
        self.ports = ports
        self.proto = proto
        self.reason = reason
    }

    /// True iff `destination` looks like a CIDR (IPv4 or IPv6)
    /// rather than a DNS name. The generator uses this to pick
    /// between "pass to <cidr>" and "resolve + pass to
    /// <resolved IPs>" rule shapes.
    public var isCIDR: Bool {
        destination.contains("/") && destination.contains(".")
            || destination.contains("/") && destination.contains(":")
    }
}

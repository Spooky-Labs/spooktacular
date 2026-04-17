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

// MARK: - PF rule generation

public enum TenantEgressPolicyPF {

    /// Emits a macOS PF rule snippet that enforces `policy` for
    /// a VM with the given source IP.
    ///
    /// The caller is responsible for knowing the VM's source
    /// IP — it's not stable across reboots because the
    /// Virtualization framework's NAT server hands out new
    /// DHCP leases on each start. Typical caller flow:
    ///
    /// 1. `spook start <vm>` — boot the VM
    /// 2. `spook ip <vm>` — resolve the current DHCP-assigned IP
    /// 3. `spook egress generate-pf --tenant T --vm V --source-ip <ip>`
    /// 4. Pipe into `sudo pfctl -a com.spooktacular.T.V -f -`
    ///
    /// Hostname rules in the policy are resolved at emit time
    /// via `Host.getaddrinfo`. Resolution failure → a comment
    /// noting the skip; the rest of the policy still emits so
    /// one flaky DNS lookup doesn't block the whole generation.
    public static func generate(
        policy: TenantEgressPolicy,
        sourceIP: String
    ) -> String {
        var out = """
            # Spooktacular egress policy
            # tenant:  \(policy.tenant.rawValue)
            # vm:      \(policy.vmName)
            # source:  \(sourceIP)
            # default: \(policy.defaultAction.rawValue)
            # created: \(policy.createdAt.ISO8601Format()) by \(policy.createdBy)

            """
        // Anchor per (tenant, vm) so rules can be flushed
        // independently without collision.
        let anchor = "com.spooktacular.\(policy.tenant.rawValue).\(policy.vmName)"
        out += "# Apply with: sudo pfctl -a \(anchor) -f <this-file>\n\n"

        // Default rule first — PF evaluates last-match, but the
        // lead comment documents intent.
        switch policy.defaultAction {
        case .deny:
            out += "# Default: deny everything not explicitly allowed\n"
            out += "block drop quick from \(sourceIP) to any\n\n"
        case .allow:
            out += "# Default: allow everything not explicitly denied\n"
            out += "pass quick from \(sourceIP) to any\n\n"
        }

        // Now the explicit rules. Later rules override earlier
        // in PF last-match semantics — we emit them AFTER the
        // default so they win.
        for (i, rule) in policy.rules.enumerated() {
            out += "# Rule \(i + 1): \(rule.reason ?? "(no reason given)")\n"
            let action = policy.defaultAction == .deny ? "pass" : "block drop"
            let proto = rule.proto == nil || rule.proto == .any ? "" : " proto \(rule.proto!.rawValue)"
            let ports: String
            if let p = rule.ports, !p.isEmpty {
                ports = " port { \(p.map(String.init).joined(separator: ", ")) }"
            } else {
                ports = ""
            }
            let destinations = resolveDestination(rule.destination)
            for dest in destinations {
                out += "\(action) quick from \(sourceIP) to \(dest)\(proto)\(ports)\n"
            }
            out += "\n"
        }

        return out
    }

    /// CIDR → single string. Hostname → resolved addresses.
    /// Resolution failure → a single comment line noting the
    /// skip, so a downstream `pfctl -f` doesn't load a
    /// syntactically-invalid file.
    private static func resolveDestination(_ dest: String) -> [String] {
        // CIDR or literal IP pass-through.
        if dest.contains("/") || dest.first?.isNumber == true || dest.contains(":") {
            return [dest]
        }
        // DNS hostname → addrinfo.
        guard let resolved = resolveHostname(dest), !resolved.isEmpty else {
            return ["# DNS resolution failed for '\(dest)' — rule skipped"]
        }
        return resolved
    }

    /// Best-effort IPv4/IPv6 resolution using `getaddrinfo`.
    /// Returns the unique set of resolved addresses.
    private static func resolveHostname(_ hostname: String) -> [String]? {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
            ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>? = nil
        let status = hostname.withCString { ptr in
            getaddrinfo(ptr, nil, &hints, &result)
        }
        guard status == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        var addresses: Set<String> = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch Int32(node.pointee.ai_family) {
            case AF_INET:
                let sin = UnsafePointer<sockaddr_in>(
                    OpaquePointer(node.pointee.ai_addr)!
                )
                var addr = sin.pointee.sin_addr
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil {
                    addresses.insert(String(cString: buf) + "/32")
                }
            case AF_INET6:
                let sin6 = UnsafePointer<sockaddr_in6>(
                    OpaquePointer(node.pointee.ai_addr)!
                )
                var addr6 = sin6.pointee.sin6_addr
                if inet_ntop(AF_INET6, &addr6, &buf, socklen_t(buf.count)) != nil {
                    addresses.insert(String(cString: buf) + "/128")
                }
            default:
                break
            }
            cursor = node.pointee.ai_next
        }
        return Array(addresses).sorted()
    }
}

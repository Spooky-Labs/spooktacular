import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Manage per-VM network egress policies.
    ///
    /// Policies are stored locally (default
    /// `~/.spooktacular/egress-policies.json`); the
    /// `generate-pf` subcommand emits macOS PF rules the
    /// operator applies with `sudo pfctl -a <anchor> -f -`.
    /// Automated application at VM start is a deliberate
    /// follow-up — `pfctl` requires root and wiring it into the
    /// VM start path is its own commit.
    struct Egress: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "egress",
            abstract: "Manage per-VM network egress policies (deny-by-default outbound filtering).",
            discussion: """
                EXAMPLES:
                  # Deny-by-default policy, allow S3 + GitHub API:
                  spook egress set --tenant team-a --vm runner-01 \\
                    --default deny \\
                    --allow 'github.com:443/tcp' \\
                    --allow 'api.github.com:443/tcp' \\
                    --allow '10.0.0.0/8:443/tcp'

                  spook egress list
                  spook egress show --tenant team-a --vm runner-01
                  spook egress generate-pf --tenant team-a --vm runner-01 \\
                    --source-ip 192.168.64.10 | \\
                      sudo pfctl -a com.spooktacular.team-a.runner-01 -f -

                  spook egress detach --tenant team-a --vm runner-01
                """,
            subcommands: [Set.self, Detach.self, List.self, Show.self, GeneratePF.self]
        )

        // MARK: - set (upsert)

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Attach or replace the egress policy for a VM."
            )

            @Option(help: "Tenant the VM belongs to.")
            var tenant: String

            @Option(help: "VM name.")
            var vm: String

            @Option(name: .customLong("default"),
                    help: "Default action: deny (recommended) or allow.")
            var defaultAction: String = "deny"

            @Option(name: .customLong("allow"),
                    help: "Destination rule: 'cidr-or-host[:ports[/proto]]'. Repeat for multiple rules.")
            var allow: [String] = []

            func run() async throws {
                guard let action = TenantEgressPolicy.DefaultAction(rawValue: defaultAction) else {
                    print(Style.error("✗ --default must be one of: deny, allow."))
                    throw ExitCode.failure
                }
                let rules = try allow.map(parseRule)
                let policy = TenantEgressPolicy(
                    tenant: TenantID(tenant),
                    vmName: vm,
                    defaultAction: action,
                    rules: rules,
                    createdBy: operatorIdentity()
                )
                let store = try JSONTenantEgressPolicyStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOK_EGRESS_POLICIES_CONFIG"]
                )
                try await store.put(policy)
                print(Style.success("✓ Egress policy stored for '\(tenant)/\(vm)'."))
                print(Style.dim("  Default: \(action.rawValue)"))
                print(Style.dim("  Rules:   \(rules.count)"))
            }
        }

        // MARK: - detach

        struct Detach: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove a VM's egress policy."
            )

            @Option(help: "Tenant the VM belongs to.")
            var tenant: String

            @Option(help: "VM name.")
            var vm: String

            func run() async throws {
                let store = try JSONTenantEgressPolicyStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOK_EGRESS_POLICIES_CONFIG"]
                )
                try await store.remove(vmName: vm, tenant: TenantID(tenant))
                print(Style.success("✓ Detached policy for '\(tenant)/\(vm)'."))
            }
        }

        // MARK: - list

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List stored egress policies."
            )

            @Option(help: "Filter by tenant.")
            var tenant: String?

            func run() async throws {
                let store = try JSONTenantEgressPolicyStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOK_EGRESS_POLICIES_CONFIG"]
                )
                let tenantFilter: TenantID? = tenant.map { TenantID($0) }
                let policies = try await store.list(tenant: tenantFilter)
                if policies.isEmpty {
                    print("(no policies)")
                    return
                }
                for p in policies {
                    print("\(p.tenant.rawValue)/\(p.vmName)\tdefault=\(p.defaultAction.rawValue)\trules=\(p.rules.count)")
                }
            }
        }

        // MARK: - show

        struct Show: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the full egress policy JSON for a VM."
            )

            @Option(help: "Tenant the VM belongs to.")
            var tenant: String

            @Option(help: "VM name.")
            var vm: String

            func run() async throws {
                let store = try JSONTenantEgressPolicyStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOK_EGRESS_POLICIES_CONFIG"]
                )
                guard let p = try await store.policy(vmName: vm, tenant: TenantID(tenant)) else {
                    print(Style.error("✗ No egress policy for '\(tenant)/\(vm)'."))
                    throw ExitCode.failure
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(p)
                print(String(data: data, encoding: .utf8) ?? "(unencodable)")
            }
        }

        // MARK: - generate-pf

        struct GeneratePF: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "generate-pf",
                abstract: "Emit macOS PF rules enforcing a policy. Pipe into `sudo pfctl -a <anchor> -f -`."
            )

            @Option(help: "Tenant the VM belongs to.")
            var tenant: String

            @Option(help: "VM name.")
            var vm: String

            @Option(name: .customLong("source-ip"),
                    help: "The VM's current source IP (get with `spook ip <vm>`).")
            var sourceIP: String

            func run() async throws {
                let store = try JSONTenantEgressPolicyStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOK_EGRESS_POLICIES_CONFIG"]
                )
                guard let p = try await store.policy(vmName: vm, tenant: TenantID(tenant)) else {
                    print(Style.error("✗ No egress policy for '\(tenant)/\(vm)'."))
                    throw ExitCode.failure
                }
                let rules = TenantEgressPolicyPF.generate(policy: p, sourceIP: sourceIP)
                print(rules, terminator: "")
            }
        }
    }
}

/// Parse a rule string like `host:443/tcp` or `10.0.0.0/8`
/// into an ``EgressRule``.
private func parseRule(_ raw: String) throws -> EgressRule {
    // Split on '/' ONCE from the right, to separate a trailing
    // "/tcp" or "/udp" suffix if present — while preserving
    // CIDR prefix lengths in the destination.
    var destAndPorts = raw
    var proto: EgressRule.Protocol_? = .any
    if raw.hasSuffix("/tcp") {
        proto = .tcp
        destAndPorts = String(raw.dropLast(4))
    } else if raw.hasSuffix("/udp") {
        proto = .udp
        destAndPorts = String(raw.dropLast(4))
    }
    // Now split on ':' — but only if the last colon is followed
    // by digits (to avoid eating IPv6 addresses).
    var destination = destAndPorts
    var ports: [Int]?
    if let colonIndex = destAndPorts.lastIndex(of: ":") {
        let after = destAndPorts[destAndPorts.index(after: colonIndex)...]
        if after.allSatisfy({ $0.isNumber || $0 == "," }) {
            let portStrs = after.split(separator: ",")
            let parsed = portStrs.compactMap { Int($0) }
            if parsed.count == portStrs.count {
                ports = parsed
                destination = String(destAndPorts[..<colonIndex])
            }
        }
    }
    return EgressRule(
        destination: destination,
        ports: ports,
        proto: proto,
        reason: "operator-authored"
    )
}

private func operatorIdentity() -> String {
    if let explicit = ProcessInfo.processInfo.environment["SPOOK_OPERATOR_IDENTITY"],
       !explicit.isEmpty {
        return explicit
    }
    return ProcessInfo.processInfo.userName
}

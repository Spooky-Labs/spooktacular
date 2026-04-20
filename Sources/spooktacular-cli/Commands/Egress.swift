import ArgumentParser
import Foundation
import SpooktacularKit

extension Spooktacular {

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
            subcommands: [Set.self, Detach.self, List.self, Show.self, Apply.self, Unapply.self]
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
                    configPath: ProcessInfo.processInfo.environment["SPOOKTACULAR_EGRESS_POLICIES_CONFIG"]
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
                    configPath: ProcessInfo.processInfo.environment["SPOOKTACULAR_EGRESS_POLICIES_CONFIG"]
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
                    configPath: ProcessInfo.processInfo.environment["SPOOKTACULAR_EGRESS_POLICIES_CONFIG"]
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
                    configPath: ProcessInfo.processInfo.environment["SPOOKTACULAR_EGRESS_POLICIES_CONFIG"]
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

        // MARK: - apply

        /// Generates PF rules for a policy and loads them
        /// into the kernel via `pfctl -a <anchor> -f -`.
        ///
        /// Requires root. The implementation detects when
        /// the current process isn't root and shells out via
        /// `sudo pfctl` — the user gets a standard macOS
        /// password prompt once per invocation. When run
        /// from inside the `spooktacular serve` LaunchDaemon
        /// (installed via `spooktacular service install`),
        /// there's no prompt because the daemon is already
        /// root.
        struct Apply: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "apply",
                abstract: "Push active egress policies to the NEFilterDataProvider system extension.",
                discussion: """
                    Loads every stored egress policy + the current \
                    VM → source-IP mapping into the system's \
                    NEFilterManager configuration. The \
                    Spooktacular system extension picks up the new \
                    configuration via the standard Network \
                    Extension configuration channel — no process \
                    restart, no sudo prompt.

                    Prerequisites:
                      1. `spooktacular egress set …` has stored at \
                         least one policy.
                      2. The Spooktacular Network Filter system \
                         extension is installed and approved in \
                         System Settings → Network → Filters. \
                         (See follow-up track for installation flow.)

                    EXAMPLES:
                      spooktacular egress apply
                """
            )

            func run() async throws {
                let store = try JSONTenantEgressPolicyStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOKTACULAR_EGRESS_POLICIES_CONFIG"]
                )
                let policies = try await store.list(tenant: nil)

                // Build the VM → source IP map by resolving
                // every VM that has a policy. The extension
                // only filters VMs it can see here; a VM
                // without a resolved IP is treated as a non-
                // VM flow (passthrough).
                var vmBySourceIP: [String: (tenant: String, vmName: String)] = [:]
                for policy in policies {
                    let vmName = policy.vmName
                    guard let bundleURL = try? SpooktacularPaths.bundleURL(for: vmName),
                          let bundle = try? VirtualMachineBundle.load(from: bundleURL),
                          let mac = bundle.spec.macAddress,
                          let ip = try? await IPResolver.resolveIP(macAddress: mac) else {
                        print(Style.dim("• \(policy.tenant.rawValue)/\(vmName): no resolved IP (not running?) — skipping"))
                        continue
                    }
                    vmBySourceIP[ip] = (tenant: policy.tenant.rawValue, vmName: vmName)
                }

                let configurator = NEFilterConfigurator()
                do {
                    try await configurator.applyPolicies(
                        policies,
                        vmBySourceIP: vmBySourceIP
                    )
                    print(Style.success("✓ Applied \(policies.count) policy(ies) covering \(vmBySourceIP.count) VM source IP(s)"))
                } catch {
                    print(Style.error("✗ \(error.localizedDescription)"))
                    print(Style.dim("  Is the Spooktacular Network Filter system extension installed + approved?"))
                    throw ExitCode.failure
                }
            }
        }

        // MARK: - unapply

        /// Removes the filter configuration from NEFilterManager.
        /// The system extension stays installed — only the
        /// policy set is cleared. Idempotent.
        struct Unapply: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "unapply",
                abstract: "Clear NEFilterManager configuration (system extension keeps running, but with no policy to enforce).",
                discussion: """
                    Removes all policies from the system's \
                    NEFilterManager configuration. Stored policies \
                    in the JSON store are untouched; re-apply with \
                    `spooktacular egress apply` to load them back.

                    EXAMPLES:
                      spooktacular egress unapply
                """
            )

            func run() async throws {
                let configurator = NEFilterConfigurator()
                do {
                    try await configurator.removeAllPolicies()
                    print(Style.success("✓ Cleared NEFilterManager configuration"))
                } catch {
                    print(Style.error("✗ \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
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
    if let explicit = ProcessInfo.processInfo.environment["SPOOKTACULAR_OPERATOR_IDENTITY"],
       !explicit.isEmpty {
        return explicit
    }
    return ProcessInfo.processInfo.userName
}

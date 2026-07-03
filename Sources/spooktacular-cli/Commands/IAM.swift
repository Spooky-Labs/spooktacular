import ArgumentParser
import Foundation
import SpooktacularKit

extension Spooktacular {

    /// Manage the VM → IAM role binding catalog.
    ///
    /// These commands operate on the local bindings file
    /// (default `~/.spooktacular/iam-bindings.json`, override
    /// with `SPOOKTACULAR_IAM_BINDINGS_CONFIG`). For remote
    /// administration against a `spook serve` instance, use
    /// `spook sign-request` with the `/v1/iam` HTTP endpoints
    /// directly.
    struct IAM: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "iam",
            abstract: "Bind Spooktacular VMs to cloud IAM roles (AWS / GCP / Azure).",
            discussion: """
                Each binding authorizes one VM to assume one \
                cloud IAM role via OIDC workload-identity \
                federation. The controller mints short-lived \
                JWTs signed with its SEP-bound issuer key; AWS \
                STS (or GCP / Azure equivalents) verifies and \
                returns temporary credentials scoped to the role.

                EXAMPLES:
                  spook iam attach \\
                    --tenant team-a --vm ci-runner-01 \\
                    --role arn:aws:iam::123456789012:role/ci-runner-builds

                  spook iam list --tenant team-a
                  spook iam show  --tenant team-a --vm ci-runner-01
                  spook iam detach --tenant team-a --vm ci-runner-01
                """,
            subcommands: [Attach.self, Detach.self, List.self, Show.self]
        )

        struct Attach: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Bind a VM to a cloud IAM role."
            )

            @Option(help: "Tenant the VM belongs to.")
            var tenant: String

            @Option(help: "VM name (scoped by tenant).")
            var vm: String

            @Option(help: "Cloud IAM role identifier (AWS ARN, GCP service account email, or Azure managed-identity path).")
            var role: String

            @Option(help: "JWT audience claim; defaults to sts.amazonaws.com.")
            var audience: String = "sts.amazonaws.com"

            @Option(name: .customLong("ttl"),
                    help: "Maximum token lifetime in seconds (60 ≤ ttl ≤ 3600).")
            var ttlSeconds: Int = 900

            @Option(name: .customLong("claim"),
                    help: "Additional claim as key=value. May be repeated.")
            var claims: [String] = []

            func run() async throws {
                guard VMIAMBindingValidation.isLikelyValidRoleARN(role) else {
                    print(Style.error("✗ '\(role)' doesn't look like a valid AWS / GCP / Azure IAM role identifier."))
                    print(Style.dim("  Accepted forms:"))
                    print(Style.dim("    AWS     arn:aws:iam::123456789012:role/ci-runner-builds"))
                    print(Style.dim("    GCP     sa@project.iam.gserviceaccount.com"))
                    print(Style.dim("    Azure   /subscriptions/.../providers/Microsoft.ManagedIdentity/..."))
                    throw ExitCode.failure
                }

                let additional: [String: String] = claims.reduce(into: [:]) { acc, kv in
                    let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else { return }
                    acc[String(parts[0])] = String(parts[1])
                }

                let binding: VMIAMBinding
                do {
                    binding = try VMIAMBinding(
                        vmName: vm,
                        tenant: TenantID(tenant),
                        roleArn: role,
                        audience: audience,
                        maxTTLSeconds: ttlSeconds,
                        additionalClaims: additional,
                        createdAt: Date(),
                        createdBy: operatorIdentity()
                    )
                } catch let err as IAMBindingError {
                    print(Style.error("✗ \(err.errorDescription ?? "Invalid IAM binding.")"))
                    if let hint = err.recoverySuggestion {
                        print(Style.dim("  \(hint)"))
                    }
                    throw ExitCode.failure
                }

                let store = try JSONVMIAMBindingStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOKTACULAR_IAM_BINDINGS_CONFIG"]
                )
                try await store.put(binding)

                print(Style.success("✓ Bound VM '\(vm)' (tenant '\(tenant)') to role '\(role)'."))
                print(Style.dim("  Audience:     \(audience)"))
                print(Style.dim("  Max TTL:      \(binding.maxTTLSeconds)s"))
                if !additional.isEmpty {
                    print(Style.dim("  Extra claims: \(additional.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))"))
                }
            }
        }

        struct Detach: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove a VM's IAM role binding."
            )

            @Option(help: "Tenant the VM belongs to.")
            var tenant: String

            @Option(help: "VM name.")
            var vm: String

            func run() async throws {
                let store = try JSONVMIAMBindingStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOKTACULAR_IAM_BINDINGS_CONFIG"]
                )
                try await store.remove(vmName: vm, tenant: TenantID(tenant))
                print(Style.success("✓ Removed binding for VM '\(vm)' (tenant '\(tenant)')."))
            }
        }

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List VM → IAM bindings."
            )

            @Option(help: "Tenant filter (omit to list across all tenants).")
            var tenant: String?

            func run() async throws {
                let store = try JSONVMIAMBindingStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOKTACULAR_IAM_BINDINGS_CONFIG"]
                )
                let tenantFilter: TenantID? = tenant.map { TenantID($0) }
                let bindings = try await store.list(tenant: tenantFilter)
                if bindings.isEmpty {
                    print("(no bindings)")
                    return
                }
                for b in bindings {
                    print("\(b.tenant.rawValue)/\(b.vmName)\t→\t\(b.roleArn)")
                }
            }
        }

        struct Show: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the full binding record for one VM."
            )

            @Option(help: "Tenant the VM belongs to.")
            var tenant: String

            @Option(help: "VM name.")
            var vm: String

            func run() async throws {
                let store = try JSONVMIAMBindingStore(
                    configPath: ProcessInfo.processInfo.environment["SPOOKTACULAR_IAM_BINDINGS_CONFIG"]
                )
                guard let b = try await store.binding(vmName: vm, tenant: TenantID(tenant)) else {
                    print(Style.error("✗ No IAM binding for VM '\(vm)' in tenant '\(tenant)'."))
                    throw ExitCode.failure
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(b)
                print(String(data: data, encoding: .utf8) ?? "(unencodable)")
            }
        }
    }
}

/// Best-effort operator identity for attribution. Uses
/// `$SPOOKTACULAR_OPERATOR_IDENTITY` when set (explicit override);
/// falls back to the current Unix username.
private func operatorIdentity() -> String {
    if let explicit = ProcessInfo.processInfo.environment["SPOOKTACULAR_OPERATOR_IDENTITY"],
       !explicit.isEmpty {
        return explicit
    }
    return ProcessInfo.processInfo.userName
}

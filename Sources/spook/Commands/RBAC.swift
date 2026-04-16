import ArgumentParser
import Foundation
import SpookCore
import SpookApplication
import SpookInfrastructureApple

extension Spook {
    /// Manage roles and assignments for access control.
    struct RBAC: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rbac",
            abstract: "Manage roles and role assignments.",
            discussion: """
                View, assign, and revoke roles for actors within tenants.
                Roles control which API operations an actor can perform.

                EXAMPLES:
                  spook rbac list-roles
                  spook rbac list-roles --tenant team-a
                  spook rbac assignments --actor user@example.com
                  spook rbac assign --actor user@example.com --role ci-operator
                  spook rbac revoke --actor user@example.com --role ci-operator
                """,
            subcommands: [
                ListRoles.self,
                Assignments.self,
                Assign.self,
                Revoke.self,
            ]
        )
    }
}

// MARK: - List Roles

extension Spook.RBAC {
    struct ListRoles: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list-roles",
            abstract: "List all available roles."
        )

        @Option(help: "Tenant ID to filter roles.")
        var tenant: String = "default"

        func run() async throws {
            let store = try JSONRoleStore(
                configPath: ProcessInfo.processInfo.environment["SPOOK_RBAC_CONFIG"]
            )
            let roles = try await store.allRoles(tenant: TenantID(tenant))

            if roles.isEmpty {
                print("No roles defined for tenant '\(tenant)'.")
                return
            }

            print("Roles for tenant '\(tenant)':\n")
            for role in roles.sorted(by: { $0.id < $1.id }) {
                let perms = role.permissions.map { "\($0.resource):\($0.action)" }
                    .sorted().joined(separator: ", ")
                print("  \(role.id) (\(role.name))")
                print("    Permissions: \(perms)")
                print()
            }
        }
    }
}

// MARK: - Assignments

extension Spook.RBAC {
    struct Assignments: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "assignments",
            abstract: "List role assignments for an actor."
        )

        @Option(help: "Actor identity to look up.")
        var actor: String

        @Option(help: "Tenant ID.")
        var tenant: String = "default"

        func run() async throws {
            let store = try JSONRoleStore(
                configPath: ProcessInfo.processInfo.environment["SPOOK_RBAC_CONFIG"]
            )
            let roles = try await store.rolesForActor(actor, tenant: TenantID(tenant))

            if roles.isEmpty {
                print("No roles assigned to '\(actor)' in tenant '\(tenant)'.")
                return
            }

            print("Roles for '\(actor)' in tenant '\(tenant)':\n")
            for role in roles {
                print("  - \(role.id) (\(role.name))")
            }
        }
    }
}

// MARK: - Assign

extension Spook.RBAC {
    struct Assign: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Assign a role to an actor."
        )

        @Option(help: "Actor identity (e.g., 'oidc/user@example.com').")
        var actor: String

        @Option(help: "Role ID to assign (e.g., 'ci-operator').")
        var role: String

        @Option(help: "Tenant ID.")
        var tenant: String = "default"

        @Option(help: "Expiry in hours (0 = no expiry).")
        var expiresIn: Int = 0

        func run() async throws {
            let store = try JSONRoleStore(
                configPath: ProcessInfo.processInfo.environment["SPOOK_RBAC_CONFIG"]
            )

            let expiry: Date? = expiresIn > 0
                ? Date().addingTimeInterval(TimeInterval(expiresIn * 3600))
                : nil

            let assignment = RoleAssignment(
                actorIdentity: actor,
                tenant: TenantID(tenant),
                role: role,
                expiresAt: expiry
            )

            try await store.assign(assignment)

            if let exp = expiry {
                print("Assigned role '\(role)' to '\(actor)' in tenant '\(tenant)' (expires: \(exp))")
            } else {
                print("Assigned role '\(role)' to '\(actor)' in tenant '\(tenant)' (no expiry)")
            }
        }
    }
}

// MARK: - Revoke

extension Spook.RBAC {
    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Revoke a role from an actor."
        )

        @Option(help: "Actor identity.")
        var actor: String

        @Option(help: "Role ID to revoke.")
        var role: String

        @Option(help: "Tenant ID.")
        var tenant: String = "default"

        func run() async throws {
            let store = try JSONRoleStore(
                configPath: ProcessInfo.processInfo.environment["SPOOK_RBAC_CONFIG"]
            )

            try await store.revoke(actor: actor, role: role, tenant: TenantID(tenant))
            print("Revoked role '\(role)' from '\(actor)' in tenant '\(tenant)'")
        }
    }
}

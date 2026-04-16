import Foundation
import SpookCore
import SpookApplication

/// Authorization service that checks macOS group membership.
///
/// Uses the `id -Gn` command to query the current user's group
/// memberships and maps them to Spooktacular roles. This is the
/// Apple-native approach for single-host deployments where users
/// are managed via macOS Directory Services.
///
/// ## Usage
///
/// Maps macOS groups to Spooktacular roles:
/// ```swift
/// let auth = MacOSGroupAuthorization(groupRoleMapping: [
///     "admin": "platform-admin",
///     "staff": "ci-operator",
///     "_developer": "viewer",
/// ])
/// ```
///
/// ## When to use
///
/// - Single-host standalone deployments
/// - Users managed via macOS Directory Services or Open Directory
/// - No external IdP needed
///
/// For multi-tenant or federated identity, use `RBACAuthorization`
/// with `OIDCTokenVerifier` or `SAMLAssertionVerifier` instead.
///
/// ## Apple API Reference
///
/// This leverages macOS's built-in user/group system via `ProcessInfo`
/// and the `id` command, which queries the DirectoryService daemon.
/// Apple's Authorization Services framework provides similar
/// functionality but is not supported in sandboxed apps.
public struct MacOSGroupAuthorization: AuthorizationService {
    private let groupRoleMapping: [String: String]
    private let roleStore: any RoleStore
    private let cachedGroups: Swift.Set<String>

    /// Creates a macOS group-based authorization service.
    ///
    /// - Parameters:
    ///   - groupRoleMapping: Maps macOS group names to role IDs.
    ///   - roleStore: The role store containing role definitions.
    public init(groupRoleMapping: [String: String], roleStore: any RoleStore) {
        self.groupRoleMapping = groupRoleMapping
        self.roleStore = roleStore
        // Query current user's groups at init time
        self.cachedGroups = Self.currentUserGroups()
    }

    public func authorize(_ context: AuthorizationContext) async -> Bool {
        // Map macOS groups to role IDs
        let roleIDs = cachedGroups.compactMap { groupRoleMapping[$0] }
        guard !roleIDs.isEmpty else { return false }

        // Look up full role definitions
        for roleID in roleIDs {
            if let roles = try? await roleStore.allRoles(tenant: context.tenant) {
                let matchingRole = roles.first { $0.id == roleID }
                if let role = matchingRole {
                    let needed = Permission(resource: context.resource, action: context.action)
                    if role.allows(needed) { return true }
                }
            }
        }
        return false
    }

    /// Queries the current user's macOS group memberships.
    private static func currentUserGroups() -> Swift.Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        process.arguments = ["-Gn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return Swift.Set(output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces))
        } catch {
            return []
        }
    }
}

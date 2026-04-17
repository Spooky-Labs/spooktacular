import Foundation
import SpookCore
import SpookApplication

/// JSON-file-backed ``TenantEgressPolicyStore``. Mirrors the
/// design of ``JSONVMIAMBindingStore`` — atomic writes,
/// GitOps-friendly file format, default path at
/// `~/.spooktacular/egress-policies.json` with env-var override
/// via `SPOOK_EGRESS_POLICIES_CONFIG`.
public actor JSONTenantEgressPolicyStore: TenantEgressPolicyStore {

    private let configPath: String?
    private var policies: [String: TenantEgressPolicy] = [:]

    public init(configPath: String? = nil) throws {
        let resolved: String?
        if let explicit = configPath {
            resolved = explicit.isEmpty ? nil : explicit
        } else {
            resolved = ProcessInfo.processInfo.environment["SPOOK_EGRESS_POLICIES_CONFIG"]
                ?? defaultPath()
        }
        self.configPath = resolved

        if let path = resolved,
           FileManager.default.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(filePath: path)),
           !data.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(PoliciesFile.self, from: data) {
                var seed: [String: TenantEgressPolicy] = [:]
                for policy in file.policies {
                    seed[policy.storeKey] = policy
                }
                self.policies = seed
            }
        }
    }

    // MARK: - TenantEgressPolicyStore

    public func policy(vmName: String, tenant: TenantID) async throws -> TenantEgressPolicy? {
        policies["\(tenant.rawValue)/\(vmName)"]
    }

    public func list(tenant: TenantID?) async throws -> [TenantEgressPolicy] {
        let all = Array(policies.values)
        if let tenant {
            return all.filter { $0.tenant == tenant }
                .sorted { $0.vmName < $1.vmName }
        }
        return all.sorted {
            $0.tenant.rawValue == $1.tenant.rawValue
                ? $0.vmName < $1.vmName
                : $0.tenant.rawValue < $1.tenant.rawValue
        }
    }

    public func put(_ policy: TenantEgressPolicy) async throws {
        policies[policy.storeKey] = policy
        try persist()
    }

    public func remove(vmName: String, tenant: TenantID) async throws {
        policies.removeValue(forKey: "\(tenant.rawValue)/\(vmName)")
        try persist()
    }

    // MARK: - Disk I/O

    fileprivate struct PoliciesFile: Codable {
        let policies: [TenantEgressPolicy]
    }

    private func persist() throws {
        guard let path = configPath else { return }
        let sorted = policies.values.sorted { $0.storeKey < $1.storeKey }
        let file = PoliciesFile(policies: sorted)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        let url = URL(filePath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

private func defaultPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.spooktacular/egress-policies.json"
}

import Foundation
import SpookCore
import SpookApplication

/// JSON-file-backed ``VMIAMBindingStore``. Binds cloud IAM
/// roles to Spooktacular VMs; the file is the authoritative
/// source of truth consulted on every identity-token mint.
///
/// ## File format
///
/// ```json
/// {
///   "bindings": [
///     {
///       "vmName": "ci-runner-01",
///       "tenant": "team-a",
///       "roleArn": "arn:aws:iam::123456789012:role/ci-runner-builds",
///       "audience": "sts.amazonaws.com",
///       "maxTTLSeconds": 900,
///       "additionalClaims": {"environment": "prod"},
///       "createdAt": "2026-04-17T18:30:00Z",
///       "createdBy": "alice@acme"
///     }
///   ]
/// }
/// ```
///
/// ## Atomic writes
///
/// `Data.write(options: .atomic)` is `rename(2)`-safe so
/// concurrent readers never see a torn binding file. Every
/// mutation reloads from disk, applies the change, and writes
/// back — this makes the binding file the source of truth and
/// lets external tooling (GitOps, Terraform state re-synthesis)
/// edit the file directly when appropriate.
public actor JSONVMIAMBindingStore: VMIAMBindingStore {
    private let configPath: String?
    private var bindings: [String: VMIAMBinding] = [:]  // keyed by storeKey

    /// - Parameter configPath: Absolute path to the bindings
    ///   file. `nil` → use the default
    ///   (`$SPOOK_IAM_BINDINGS_CONFIG` or
    ///   `~/.spooktacular/iam-bindings.json`). Empty string →
    ///   in-memory only.
    public init(configPath: String? = nil) throws {
        let resolved: String?
        if let explicit = configPath {
            resolved = explicit.isEmpty ? nil : explicit
        } else {
            resolved = ProcessInfo.processInfo.environment["SPOOK_IAM_BINDINGS_CONFIG"]
                ?? defaultPath()
        }
        self.configPath = resolved
        // Synchronous seed from disk — equivalent to what
        // loadFromDisk does, but callable from the nonisolated
        // initializer. Actor isolation kicks in for subsequent
        // mutations.
        if let path = resolved,
           FileManager.default.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(filePath: path)),
           !data.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(BindingsFile.self, from: data) {
                var seed: [String: VMIAMBinding] = [:]
                for binding in file.bindings {
                    seed[binding.storeKey] = binding
                }
                self.bindings = seed
            }
        }
    }

    // MARK: - VMIAMBindingStore

    public func binding(vmName: String, tenant: TenantID) async throws -> VMIAMBinding? {
        bindings["\(tenant.rawValue)/\(vmName)"]
    }

    public func list(tenant: TenantID?) async throws -> [VMIAMBinding] {
        let all = Array(bindings.values)
        if let tenant {
            return all.filter { $0.tenant == tenant }
                .sorted { $0.vmName < $1.vmName }
        }
        return all.sorted { lhs, rhs in
            lhs.tenant.rawValue == rhs.tenant.rawValue
                ? lhs.vmName < rhs.vmName
                : lhs.tenant.rawValue < rhs.tenant.rawValue
        }
    }

    public func put(_ binding: VMIAMBinding) async throws {
        bindings[binding.storeKey] = binding
        try persist()
    }

    public func remove(vmName: String, tenant: TenantID) async throws {
        bindings.removeValue(forKey: "\(tenant.rawValue)/\(vmName)")
        try persist()
    }

    // MARK: - Disk I/O

    fileprivate struct BindingsFile: Codable {
        let bindings: [VMIAMBinding]
    }

    private func persist() throws {
        guard let path = configPath else { return }
        let sorted = bindings.values.sorted { lhs, rhs in
            lhs.storeKey < rhs.storeKey
        }
        let file = BindingsFile(bindings: sorted)
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

/// Default config path: `~/.spooktacular/iam-bindings.json`.
/// Separate file from the RBAC config because IAM bindings are
/// per-VM and rotate on different cadence than role assignments.
private func defaultPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.spooktacular/iam-bindings.json"
}

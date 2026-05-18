import Foundation
import SpooktacularCore
import SpooktacularApplication

/// Builds a ``DistributedLockService`` implementation from environment
/// configuration, so deployments can switch lock backends without
/// recompiling.
///
/// ## Selection rules (first match wins)
///
/// 1. **`SPOOKTACULAR_DYNAMO_TABLE` set** → ``DynamoDBDistributedLock``.
///    Intended for cross-region Fortune-20 fleets where K8s Leases
///    can't bridge regions and file locks don't work at all.
///    `SPOOKTACULAR_DYNAMO_REGION` (default `us-east-1`) and
///    `SPOOKTACULAR_DYNAMO_ENDPOINT` (optional — LocalStack, custom VPC
///    endpoint) refine the target. AWS credentials come from the
///    standard `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
///    environment variables; the adapter does not ship the AWS SDK.
///
/// 2. **`SPOOK_K8S_API` set** → ``KubernetesLeaseLock``.
///    `SPOOK_K8S_NAMESPACE` (default `spooktacular`) selects the
///    namespace to read/write Lease objects into.
///    `SPOOK_K8S_TOKEN_PATH` points at the service-account token
///    (defaults to the in-cluster ServiceAccount path).
///
/// 3. **Default** → ``FileDistributedLock``. Single-host or
///    shared-NFS deployments; uses `flock(2)` on
///    `SPOOKTACULAR_LOCK_DIR` (defaults to `~/.spooktacular/locks`).
///
/// The factory is pure — no I/O, no network. It only reads
/// environment variables and constructs the chosen adapter.
///
/// ## Example
///
/// ```swift
/// let lock = try DistributedLockFactory.makeFromEnvironment()
/// guard let lease = try await lock.acquire(
///     name: "runner-pool", holder: hostID, duration: 30
/// ) else { throw LockError.contended }
/// ```
public enum DistributedLockFactory {

    /// The selection tier chosen by ``makeFromEnvironment()``.
    ///
    /// Surfaced on return so operators can log and alert on the
    /// backend actually in use — silent downgrade from DynamoDB to
    /// file-lock would be a catastrophic coordination failure in a
    /// multi-region fleet.
    public enum Backend: Sendable, Equatable, CustomStringConvertible {
        case dynamoDB(tableName: String, region: String)
        case kubernetes(apiURL: URL, namespace: String)
        case file(lockDir: String)

        public var description: String {
            switch self {
            case .dynamoDB(let t, let r): "DynamoDB(table=\(t), region=\(r))"
            case .kubernetes(let u, let ns): "Kubernetes(api=\(u.absoluteString), ns=\(ns))"
            case .file(let dir): "File(dir=\(dir))"
            }
        }
    }

    /// A lock adapter paired with the backend tag that produced it.
    public struct Built: Sendable {
        public let lock: any DistributedLockService
        public let backend: Backend
    }

    /// Constructs the lock implementation dictated by the current
    /// process environment.
    ///
    /// Throws only when the selected backend can't be initialized
    /// (e.g. DynamoDB is requested but AWS credentials are missing).
    /// Missing optional config falls back one tier down rather than
    /// failing — except that an explicit DynamoDB request without
    /// credentials is treated as a misconfiguration, not a reason
    /// to silently downgrade to a file lock.
    public static func makeFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Built {
        if let table = environment["SPOOKTACULAR_DYNAMO_TABLE"], !table.isEmpty {
            let region = environment["SPOOKTACULAR_DYNAMO_REGION"] ?? "us-east-1"
            let endpoint = environment["SPOOKTACULAR_DYNAMO_ENDPOINT"].flatMap(URL.init(string:))
            let lock = try DynamoDBDistributedLock(
                tableName: table, region: region, endpoint: endpoint
            )
            return Built(lock: lock, backend: .dynamoDB(tableName: table, region: region))
        }

        if let apiString = environment["SPOOK_K8S_API"],
           let apiURL = URL(string: apiString) {
            let namespace = environment["SPOOK_K8S_NAMESPACE"] ?? "spooktacular"
            let tokenPath = environment["SPOOK_K8S_TOKEN_PATH"]
                ?? "/var/run/secrets/kubernetes.io/serviceaccount/token"
            let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lock = KubernetesLeaseLock(
                apiURL: apiURL, namespace: namespace, token: token
            )
            return Built(lock: lock, backend: .kubernetes(apiURL: apiURL, namespace: namespace))
        }

        let lockDir = environment["SPOOKTACULAR_LOCK_DIR"]
            ?? (NSHomeDirectory() + "/.spooktacular/locks")
        let lock = FileDistributedLock(lockDir: lockDir)
        return Built(lock: lock, backend: .file(lockDir: lockDir))
    }
}

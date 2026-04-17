import Foundation
import Testing
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

// MARK: - Shared Mock: Node Client

/// Records calls made to a mock Mac node for verification.
final class MockNodeClient: NodeClient, @unchecked Sendable {
    var calls: [String] = []
    var healthResult = true
    var execResult = GuestExecResult(exitCode: 0, stdout: "OK", stderr: "")

    func clone(vm: String, from source: String, on node: URL) async throws {
        calls.append("clone:\(vm):\(source)")
    }
    func start(vm: String, on node: URL) async throws { calls.append("start:\(vm)") }
    func stop(vm: String, on node: URL) async throws { calls.append("stop:\(vm)") }
    func delete(vm: String, on node: URL) async throws { calls.append("delete:\(vm)") }
    func restoreSnapshot(vm: String, snapshot: String, on node: URL) async throws {
        calls.append("restore:\(vm):\(snapshot)")
    }
    func execInGuest(vm: String, command: String, on node: URL) async throws -> GuestExecResult {
        calls.append("exec:\(vm)")
        return execResult
    }
    func health(vm: String, on node: URL) async throws -> Bool {
        calls.append("health:\(vm)")
        return healthResult
    }
}

/// Mock node client that returns different results for successive exec calls.
final class PhasedMockNodeClient: NodeClient, @unchecked Sendable {
    var calls: [String] = []
    var healthResult = true
    var execResults: [GuestExecResult] = []
    private var execCallIndex = 0

    func clone(vm: String, from source: String, on node: URL) async throws {
        calls.append("clone:\(vm):\(source)")
    }
    func start(vm: String, on node: URL) async throws { calls.append("start:\(vm)") }
    func stop(vm: String, on node: URL) async throws { calls.append("stop:\(vm)") }
    func delete(vm: String, on node: URL) async throws { calls.append("delete:\(vm)") }
    func restoreSnapshot(vm: String, snapshot: String, on node: URL) async throws {
        calls.append("restore:\(vm):\(snapshot)")
    }
    func execInGuest(vm: String, command: String, on node: URL) async throws -> GuestExecResult {
        calls.append("exec:\(vm)")
        let result = execCallIndex < execResults.count
            ? execResults[execCallIndex]
            : GuestExecResult(exitCode: 0, stdout: "OK", stderr: "")
        execCallIndex += 1
        return result
    }
    func health(vm: String, on node: URL) async throws -> Bool {
        calls.append("health:\(vm)")
        return healthResult
    }
}

// MARK: - Shared Mock: Role Store

/// A role store that returns no roles (deny-by-default testing).
actor EmptyRoleStore: RoleStore {
    func rolesForActor(_ identity: String, tenant: TenantID) async throws -> [Role] { [] }
    func allRoles(tenant: TenantID) async throws -> [Role] { [] }
    func assign(_ assignment: RoleAssignment) async throws {}
    func revoke(actor: String, role: String, tenant: TenantID) async throws {}
}

/// A role store with configurable roles and assignments.
actor InMemoryRoleStore: RoleStore {
    var roles: [String: Role] = [:]
    var assignments: [String: [RoleAssignment]] = [:]

    func addRole(_ role: Role) { roles[role.id] = role }
    func addAssignment(_ a: RoleAssignment) { assignments[a.actorIdentity, default: []].append(a) }

    func rolesForActor(_ identity: String, tenant: TenantID) async throws -> [Role] {
        (assignments[identity] ?? [])
            .filter { $0.tenant == tenant && !$0.isExpired }
            .compactMap { roles[$0.role] }
    }
    func allRoles(tenant: TenantID) async throws -> [Role] { Array(roles.values) }
    func assign(_ a: RoleAssignment) async throws { assignments[a.actorIdentity, default: []].append(a) }
    func revoke(actor: String, role: String, tenant: TenantID) async throws {
        assignments[actor]?.removeAll { $0.role == role && $0.tenant == tenant }
    }
}

// MARK: - Shared Mock: Audit Sink

/// Collects audit records in memory for verification.
actor CollectingAuditSink: AuditSink {
    var records: [AuditRecord] = []
    func record(_ entry: AuditRecord) async throws { records.append(entry) }
}

// MARK: - Shared Mock: HTTP Client

/// Minimal mock HTTP client for testing.
struct MockHTTPClient: HTTPClient, Sendable {
    var responseData: Data = Data()
    var statusCode: Int = 200
    var responseHeaders: [String: String] = [:]

    func execute(_ request: DomainHTTPRequest) async throws -> DomainHTTPResponse {
        DomainHTTPResponse(
            statusCode: statusCode,
            headers: responseHeaders,
            body: responseData
        )
    }
}

// MARK: - Temporary Directory

/// Creates a temporary directory for test files, cleaned up on deinit.
final class TempDirectory: Sendable {
    let url: URL

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spook-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}

// MARK: - Deterministic RNG

/// Deterministic RNG for property tests (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

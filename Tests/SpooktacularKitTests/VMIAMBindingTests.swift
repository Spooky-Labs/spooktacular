import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

/// Tests for ``VMIAMBinding`` + its stores. Covers:
///
/// - Value-type invariants (TTL clamped to 60..3600)
/// - Role-ARN validation for the three cloud providers
/// - Store CRUD round-trips (in-memory + JSON file)
/// - Multi-tenant scoping (same vm name in two tenants → two bindings)
@Suite("VMIAMBinding", .tags(.security, .identity, .configuration))
struct VMIAMBindingTests {

    // MARK: - Model

    @Test("Default TTL is 900 seconds")
    func defaultTTL() throws {
        let b = try VMIAMBinding(
            vmName: "runner-01", tenant: TenantID("acme"),
            roleArn: "arn:aws:iam::123456789012:role/x",
            createdBy: "test"
        )
        #expect(b.maxTTLSeconds == 900)
    }

    @Test("TTL below the allowed range is rejected with a typed error")
    func ttlTooLowThrows() {
        #expect(throws: IAMBindingError.ttlOutOfRange(requested: 30, allowedMin: 60, allowedMax: 3600)) {
            _ = try VMIAMBinding(
                vmName: "v", tenant: TenantID("t"),
                roleArn: "arn:aws:iam::1:role/x",
                maxTTLSeconds: 30, createdBy: "test"
            )
        }
    }

    @Test("TTL above the allowed range is rejected with a typed error")
    func ttlTooHighThrows() {
        #expect(throws: IAMBindingError.ttlOutOfRange(requested: 7200, allowedMin: 60, allowedMax: 3600)) {
            _ = try VMIAMBinding(
                vmName: "v", tenant: TenantID("t"),
                roleArn: "arn:aws:iam::1:role/x",
                maxTTLSeconds: 7200, createdBy: "test"
            )
        }
    }

    @Test("TTLs at the bounds are accepted exactly")
    func ttlBoundsAccepted() throws {
        let lowest = try VMIAMBinding(
            vmName: "v", tenant: TenantID("t"),
            roleArn: "arn:aws:iam::1:role/x",
            maxTTLSeconds: 60, createdBy: "test"
        )
        #expect(lowest.maxTTLSeconds == 60)
        let highest = try VMIAMBinding(
            vmName: "v", tenant: TenantID("t"),
            roleArn: "arn:aws:iam::1:role/x",
            maxTTLSeconds: 3600, createdBy: "test"
        )
        #expect(highest.maxTTLSeconds == 3600)
    }

    @Test("storeKey composes tenant + vmName")
    func storeKeyFormat() throws {
        let b = try VMIAMBinding(
            vmName: "runner-01", tenant: TenantID("team-a"),
            roleArn: "arn:aws:iam::1:role/x", createdBy: "test"
        )
        #expect(b.storeKey == "team-a/runner-01")
    }

    // MARK: - Role-ARN validation

    @Test("AWS role ARN forms are accepted")
    func validAWSARNs() {
        #expect(VMIAMBindingValidation.isLikelyValidRoleARN(
            "arn:aws:iam::123456789012:role/ci-runner-builds"
        ))
        #expect(VMIAMBindingValidation.isLikelyValidRoleARN(
            "arn:aws-us-gov:iam::123456789012:role/gov-role"
        ))
        #expect(VMIAMBindingValidation.isLikelyValidRoleARN(
            "arn:aws-cn:iam::123456789012:role/china-role"
        ))
        #expect(VMIAMBindingValidation.isLikelyValidRoleARN(
            "arn:aws:iam::123456789012:role/nested/path/role"
        ))
    }

    @Test("GCP service account email is accepted")
    func validGCP() {
        #expect(VMIAMBindingValidation.isLikelyValidRoleARN(
            "sa-runner@my-project.iam.gserviceaccount.com"
        ))
    }

    @Test("Azure managed-identity path is accepted")
    func validAzure() {
        #expect(VMIAMBindingValidation.isLikelyValidRoleARN(
            "/subscriptions/abcd-1234/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ci"
        ))
    }

    @Test("Obvious garbage is rejected")
    func invalidARNs() {
        #expect(!VMIAMBindingValidation.isLikelyValidRoleARN(""))
        #expect(!VMIAMBindingValidation.isLikelyValidRoleARN("role-name"))
        #expect(!VMIAMBindingValidation.isLikelyValidRoleARN("arn:something:else"))
        #expect(!VMIAMBindingValidation.isLikelyValidRoleARN("arn:aws:iam::123:user/me"),
                "IAM user ARNs must not be accepted — only roles")
    }

    // MARK: - In-memory store

    @Test("In-memory store: put / get / list / remove round-trip")
    func inMemoryRoundTrip() async throws {
        let store = InMemoryVMIAMBindingStore()
        let b = try VMIAMBinding(
            vmName: "runner-01", tenant: TenantID("team-a"),
            roleArn: "arn:aws:iam::1:role/x", createdBy: "alice"
        )
        try await store.put(b)
        let fetched = try await store.binding(vmName: "runner-01", tenant: TenantID("team-a"))
        #expect(fetched?.roleArn == "arn:aws:iam::1:role/x")

        let list = try await store.list(tenant: TenantID("team-a"))
        #expect(list.count == 1)

        try await store.remove(vmName: "runner-01", tenant: TenantID("team-a"))
        let afterRemove = try await store.binding(vmName: "runner-01", tenant: TenantID("team-a"))
        #expect(afterRemove == nil)
    }

    @Test("In-memory store: same VM name in different tenants → separate bindings")
    func multiTenantIsolation() async throws {
        let store = InMemoryVMIAMBindingStore()
        try await store.put(try VMIAMBinding(
            vmName: "runner-01", tenant: TenantID("team-a"),
            roleArn: "arn:aws:iam::1:role/a", createdBy: "alice"
        ))
        try await store.put(try VMIAMBinding(
            vmName: "runner-01", tenant: TenantID("team-b"),
            roleArn: "arn:aws:iam::1:role/b", createdBy: "bob"
        ))
        let a = try await store.binding(vmName: "runner-01", tenant: TenantID("team-a"))
        let b = try await store.binding(vmName: "runner-01", tenant: TenantID("team-b"))
        #expect(a?.roleArn == "arn:aws:iam::1:role/a")
        #expect(b?.roleArn == "arn:aws:iam::1:role/b")
    }

    // MARK: - JSON file store

    @Test("JSON store: persistence survives a restart (same file)")
    func jsonStorePersists() async throws {
        let tmp = NSTemporaryDirectory() + "iam-bindings-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let binding = try VMIAMBinding(
            vmName: "runner-01", tenant: TenantID("team-a"),
            roleArn: "arn:aws:iam::1:role/x",
            additionalClaims: ["environment": "prod"],
            createdBy: "alice"
        )

        let writer = try JSONVMIAMBindingStore(configPath: tmp)
        try await writer.put(binding)

        // Second store instance loads from disk.
        let reader = try JSONVMIAMBindingStore(configPath: tmp)
        let loaded = try await reader.binding(vmName: "runner-01", tenant: TenantID("team-a"))
        #expect(loaded?.roleArn == "arn:aws:iam::1:role/x")
        #expect(loaded?.additionalClaims["environment"] == "prod")
    }

    @Test("JSON store with empty configPath is in-memory only")
    func jsonStoreInMemoryMode() async throws {
        let store = try JSONVMIAMBindingStore(configPath: "")
        try await store.put(try VMIAMBinding(
            vmName: "v", tenant: TenantID("t"),
            roleArn: "arn:aws:iam::1:role/x",
            createdBy: "alice"
        ))
        // No file was created; we can still read back in-process.
        let got = try await store.binding(vmName: "v", tenant: TenantID("t"))
        #expect(got != nil)
    }
}

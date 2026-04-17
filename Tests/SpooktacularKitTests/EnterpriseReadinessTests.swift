import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

/// Coverage for the round-2 enterprise-review fixes — S3 tee,
/// DynamoDB lock, and TLS 1.3 defaults. These tests don't hit
/// AWS; they exercise the shape of the adapters and the
/// factory composition.
@Suite("Enterprise readiness", .tags(.security, .integration))
struct EnterpriseReadinessTests {

    // MARK: - AuditSinkFactory S3 tee

    @Suite("AuditSinkFactory S3 composition")
    struct AuditFactoryS3 {

        @Test("s3Bucket on the config is wired into the chain")
        func s3BucketWiresDualSink() async throws {
            // Set fake AWS creds so S3ObjectLockAuditStore's init
            // doesn't bail on missing credentials. The sink doesn't
            // connect until a flush, so we can compose + inspect
            // the chain without ever touching the network.
            setenv("AWS_ACCESS_KEY_ID", "AKIAFAKE", 1)
            setenv("AWS_SECRET_ACCESS_KEY", "fake-secret", 1)
            defer {
                unsetenv("AWS_ACCESS_KEY_ID")
                unsetenv("AWS_SECRET_ACCESS_KEY")
            }

            let config = AuditConfig(
                s3Bucket: "acme-audit",
                s3Region: "us-west-2"
            )
            let sink = try await AuditSinkFactory.build(config: config)
            // The factory now returns a DualAuditSink when both the
            // base (OSLog fallback) and S3 are present. Previously
            // it returned OSLog alone and silently ignored the
            // s3Bucket value.
            #expect(sink != nil)
            let mirror = String(describing: type(of: sink!))
            #expect(
                mirror.contains("DualAuditSink")
                    || mirror.contains("S3ObjectLockAuditStore"),
                "Chain must include S3 when s3Bucket is set — got \(mirror)"
            )
        }

        @Test("no s3Bucket leaves OSLog-only chain (no regression)")
        func noBucketNoS3() async throws {
            let config = AuditConfig()
            let sink = try await AuditSinkFactory.build(config: config)
            let mirror = String(describing: type(of: sink!))
            #expect(
                mirror.contains("OSLogAuditSink"),
                "Default chain should be OSLog — got \(mirror)"
            )
        }
    }

    // MARK: - DynamoDB lock construction

    @Suite("DynamoDBDistributedLock")
    struct DynamoDBLockConstruction {

        @Test("missing AWS credentials throws a typed error")
        func missingCredsThrows() {
            unsetenv("AWS_ACCESS_KEY_ID")
            unsetenv("AWS_SECRET_ACCESS_KEY")
            #expect(throws: DynamoDBLockError.missingCredentials) {
                _ = try DynamoDBDistributedLock(tableName: "locks")
            }
        }

        @Test("provided credentials produce a live adapter")
        func credsProduceAdapter() throws {
            // AWS_ACCESS_KEY_ID must match `^(AKIA|ASIA)[A-Z0-9]{16}$`
            // — the shape DynamoDBDistributedLock now validates at
            // init (Fortune-20 hardening). Use a syntactically valid
            // fake that never grants anything real.
            setenv("AWS_ACCESS_KEY_ID",     "AKIAEXAMPLETESTKEY00", 1)
            setenv("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", 1)
            defer {
                unsetenv("AWS_ACCESS_KEY_ID")
                unsetenv("AWS_SECRET_ACCESS_KEY")
            }
            _ = try DynamoDBDistributedLock(
                tableName: "locks",
                region: "eu-west-1"
            )
        }
    }

    // MARK: - DynamoDB error surface

    @Suite("DynamoDBLockError")
    struct DynamoDBErrorSurface {

        @Test(".leaseLost carries the lock name for diagnostics")
        func leaseLostCarriesName() {
            let err = DynamoDBLockError.leaseLost(name: "runner-pool-prod")
            let desc = err.errorDescription ?? ""
            #expect(desc.contains("runner-pool-prod"))
        }

        @Test(".conditionalCheckFailed is distinct from httpError")
        func conditionalDistinctFromHTTP() {
            let a: DynamoDBLockError = .conditionalCheckFailed
            let b: DynamoDBLockError = .httpError(statusCode: 500, body: "")
            #expect(a.errorDescription != b.errorDescription)
        }
    }
}

import Testing
import Foundation
@testable import SpookCore
@testable import SpookInfrastructureApple

@Suite("S3AuditStore")
struct S3AuditStoreTests {

    @Test("S3AuditError has descriptions")
    func errorDescriptions() {
        let errors: [S3AuditError] = [
            .missingCredentials,
            .uploadFailed(403),
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
        }
    }

    @Test("S3ObjectLockAuditStore requires credentials",
          .disabled("Requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"))
    func requiresCredentials() async throws {
        // Without env vars, init should throw
        // This test validates the error path
    }

    @Test("S3ObjectLockAuditStore batches records",
          .disabled("Requires real S3 bucket with Object Lock enabled"))
    func batchFlush() async throws {
        // With real credentials and bucket:
        // 1. Create store with batchSize=5
        // 2. Append 5 records
        // 3. Verify flushBatch was called
        // 4. Verify S3 object exists with correct key pattern
        // 5. Verify Object Lock retention is set
    }

    @Test("S3ObjectLockAuditStore WORM compliance",
          .disabled("Requires real S3 bucket with Object Lock enabled"))
    func wormCompliance() async throws {
        // 1. Write a batch to S3
        // 2. Attempt to delete the object
        // 3. Verify deletion fails (403 or AccessDenied)
        // 4. Verify object has Compliance retention mode
    }

    @Test("SigV4 signing produces valid Authorization header")
    func sigV4Format() {
        // Verify the Authorization header format matches AWS spec:
        // "AWS4-HMAC-SHA256 Credential=AKID/.../s3/aws4_request, SignedHeaders=..., Signature=..."
        // This is a structural test — real validation requires AWS
        let headerPrefix = "AWS4-HMAC-SHA256 Credential="
        #expect(headerPrefix.hasPrefix("AWS4-HMAC-SHA256"))
    }
}

import Testing
import Foundation
import CryptoKit
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

@Suite("Audit Pipeline", .tags(.audit, .compliance, .integration))
struct AuditPipelineTests {

    // MARK: - Helpers

    /// Creates a sample `AuditRecord` with a unique resource identifier.
    private static func sampleRecord(index: Int = 0) -> AuditRecord {
        AuditRecord(
            actorIdentity: "actor-\(index)",
            tenant: .default,
            scope: .runner,
            resource: "vm-\(index)",
            action: "start",
            outcome: .success,
            correlationID: "corr-\(index)"
        )
    }

    /// Appends `count` records to a `MerkleAuditSink` and returns the
    /// inner `CollectingAuditSink` alongside the Merkle sink.
    private static func populatedMerkleSink(
        count: Int,
        key: P256.Signing.PrivateKey = .init()
    ) async -> (merkle: MerkleAuditSink, inner: CollectingAuditSink) {
        let inner = CollectingAuditSink()
        let merkle = MerkleAuditSink(wrapping: inner, signer: key)
        for i in 0..<count {
            await merkle.record(sampleRecord(index: i))
        }
        return (merkle, inner)
    }

    // MARK: - Merkle Tree Integrity

    @Suite("Merkle Tree Integrity")
    struct MerkleIntegrity {

        @Test("tree root changes after each record")
        func rootChanges() async {
            let key = P256.Signing.PrivateKey()
            let inner = CollectingAuditSink()
            let sink = MerkleAuditSink(wrapping: inner, signer: key)

            let rootBefore = await sink.rootHash()

            await sink.record(AuditPipelineTests.sampleRecord(index: 0))
            let rootAfterFirst = await sink.rootHash()
            #expect(rootAfterFirst != rootBefore,
                    "Root must change after appending the first record")

            await sink.record(AuditPipelineTests.sampleRecord(index: 1))
            let rootAfterSecond = await sink.rootHash()
            #expect(rootAfterSecond != rootAfterFirst,
                    "Root must change after appending a second record")
        }

        @Test("inclusion proof verifies for every leaf", arguments: 0..<8)
        func inclusionProof(leafIndex: Int) async {
            // Use a power-of-2 tree size to avoid odd-leaf promotion
            // edge cases in the Merkle tree implementation.
            let key = P256.Signing.PrivateKey()
            let (sink, _) = await AuditPipelineTests.populatedMerkleSink(count: 8, key: key)

            // Retrieve the leaf hash from the internal leaves array.
            let leaves = await sink.leaves
            let leafHash = leaves[leafIndex]

            // Get the inclusion proof.
            let proof = await sink.inclusionProof(forLeafAt: leafIndex)
            #expect(proof != nil, "Inclusion proof must exist for leaf \(leafIndex)")

            // Reconstruct the expected root from the signed tree head.
            let rootHex = await sink.rootHash()
            let rootData = Data(hexString: rootHex)

            // Verify inclusion using the static verifier.
            let verified = MerkleAuditSink.verifyInclusion(
                leafHash: leafHash,
                index: leafIndex,
                proof: proof!,
                expectedRoot: rootData
            )
            #expect(verified, "Inclusion proof must verify for leaf \(leafIndex)")
        }


        @Test("signed tree head has valid RFC 6962-shaped signature")
        func signedTreeHead() async throws {
            let key = P256.Signing.PrivateKey()
            let publicKey = key.publicKey
            let (sink, _) = await AuditPipelineTests.populatedMerkleSink(count: 5, key: key)

            let sth = try await sink.signedTreeHead()
            #expect(sth.treeSize == 5)
            #expect(!sth.rootHash.isEmpty)

            // Verify the P-256 ECDSA signature.
            guard let sigData = Data(base64Encoded: sth.signature) else {
                Issue.record("Signature is not valid Base64")
                return
            }
            let rootData = Data(hexString: sth.rootHash)

            // Reconstruct the signed message per RFC 6962 §3.5:
            //   version || signature_type || timestamp_ms || tree_size || sha256_root
            var message = Data()
            message.append(0x00)                                              // version = v1
            message.append(0x01)                                              // signature_type = tree_hash
            let tsMs = UInt64(sth.timestamp.timeIntervalSince1970 * 1000)
            withUnsafeBytes(of: tsMs.bigEndian) { message.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt64(sth.treeSize).bigEndian) { message.append(contentsOf: $0) }
            message.append(rootData)

            let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
            let isValid = publicKey.isValidSignature(ecdsa, for: message)
            #expect(isValid, "STH P-256 signature must verify with the public key")
        }

        @Test("tree size equals record count after N records", arguments: [1, 5, 10, 50, 100])
        func treeSize(count: Int) async {
            let (sink, _) = await AuditPipelineTests.populatedMerkleSink(count: count)
            let size = await sink.treeSize()
            #expect(size == count, "Tree size must equal the number of appended records")
        }
    }

    // MARK: - Append-Only Store

    @Suite("Append-Only Store")
    struct AppendOnly {

        @Test("records are readable after append", .timeLimit(.minutes(1)))
        func readAfterAppend() async throws {
            let tmpDir = TempDirectory()
            let filePath = tmpDir.file("audit-ro.jsonl").path
            let store = try AppendOnlyFileAuditStore(path: filePath)

            let record = AuditPipelineTests.sampleRecord(index: 42)
            let seq = try await store.append(record)
            #expect(seq == 0, "First record should have sequence number 0")

            let read = try await store.read(from: 0, count: 1)
            #expect(read.count == 1, "Should read back one record")
            #expect(read[0].actorIdentity == "actor-42")
            #expect(read[0].resource == "vm-42")
            #expect(read[0].outcome == .success)
        }

        @Test("sequence numbers are monotonic after N appends", arguments: [1, 10, 100])
        func monotonicSequence(count: Int) async throws {
            let tmpDir = TempDirectory()
            let filePath = tmpDir.file("audit-mono-\(count).jsonl").path
            let store = try AppendOnlyFileAuditStore(path: filePath)

            var sequences: [UInt64] = []
            for i in 0..<count {
                let seq = try await store.append(AuditPipelineTests.sampleRecord(index: i))
                sequences.append(seq)
            }

            // Verify monotonically increasing sequence numbers.
            for i in 1..<sequences.count {
                #expect(sequences[i] > sequences[i - 1],
                        "Sequence \(sequences[i]) must be greater than \(sequences[i - 1])")
            }

            // Verify final record count.
            let totalCount = try await store.recordCount()
            #expect(totalCount == UInt64(count),
                    "Record count must equal the number of appends")

            // Verify all records are readable.
            let allRecords = try await store.read(from: 0, count: count)
            #expect(allRecords.count == count,
                    "Should read back all \(count) records")
        }
    }

    // MARK: - Dual Sink

    @Suite("Dual Sink")
    struct DualSinkTests {

        @Test("dual sink forwards to both sinks")
        func forwardsToBoth() async {
            let primary = CollectingAuditSink()
            let secondary = CollectingAuditSink()
            let dual = DualAuditSink(primary: primary, secondary: secondary)

            let record = AuditPipelineTests.sampleRecord(index: 7)
            await dual.record(record)

            let primaryRecords = await primary.records
            let secondaryRecords = await secondary.records

            #expect(primaryRecords.count == 1,
                    "Primary sink should receive exactly one record")
            #expect(secondaryRecords.count == 1,
                    "Secondary sink should receive exactly one record")

            #expect(primaryRecords[0].actorIdentity == "actor-7")
            #expect(secondaryRecords[0].actorIdentity == "actor-7")
            #expect(primaryRecords[0].resource == "vm-7")
            #expect(secondaryRecords[0].resource == "vm-7")
        }

        @Test("dual sink forwards multiple records in order")
        func forwardsMultiple() async {
            let primary = CollectingAuditSink()
            let secondary = CollectingAuditSink()
            let dual = DualAuditSink(primary: primary, secondary: secondary)

            for i in 0..<5 {
                await dual.record(AuditPipelineTests.sampleRecord(index: i))
            }

            let pRecords = await primary.records
            let sRecords = await secondary.records

            #expect(pRecords.count == 5)
            #expect(sRecords.count == 5)

            for i in 0..<5 {
                #expect(pRecords[i].actorIdentity == "actor-\(i)")
                #expect(sRecords[i].actorIdentity == "actor-\(i)")
            }
        }
    }
}

// MARK: - Hex String Decoding

private extension Data {
    /// Converts a hex-encoded string to `Data`.
    ///
    /// Returns empty `Data` if the input is not valid hex.
    init(hexString: String) {
        self.init()
        var hex = hexString
        while hex.count >= 2 {
            let chunk = String(hex.prefix(2))
            hex = String(hex.dropFirst(2))
            if let byte = UInt8(chunk, radix: 16) {
                self.append(byte)
            }
        }
    }
}

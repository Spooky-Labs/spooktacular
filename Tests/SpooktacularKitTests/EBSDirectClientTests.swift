import Foundation
import Testing
@testable import SpooktacularInfrastructureApple

/// Track-M DTO coverage for `EBSDirectClient`. The DTOs pin
/// the exact JSON shape AWS's EBS Direct API returns — a
/// regression here would break every read-path call.
///
/// Live-network tests (real AWS) live outside this suite
/// because they need IAM credentials; the CI runner we
/// target doesn't have them. This suite sticks to local
/// Codable round-trip + field-name correctness.
@Suite("EBS Direct DTOs", .tags(.infrastructure))
struct EBSDirectClientTests {

    @Test("ListSnapshotBlocksResponse decodes a happy-path AWS response")
    func listResponseDecode() throws {
        // Exact JSON shape from AWS's
        // `ListSnapshotBlocks` reference (2026-04-19):
        // https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_ebs_ListSnapshotBlocks.html
        let json = """
        {
          "Blocks": [
            { "BlockIndex": 0, "BlockToken": "AAABAVahng3S..." },
            { "BlockIndex": 1, "BlockToken": "AAABAW2znbcL..." }
          ],
          "ExpiryTime": 1.708543200E9,
          "VolumeSize": 100,
          "BlockSize": 524288,
          "NextToken": "eyJmaXJzdFRva2VuIjog..."
        }
        """
        let decoded = try JSONDecoder().decode(
            ListSnapshotBlocksResponse.self,
            from: Data(json.utf8)
        )
        #expect(decoded.Blocks.count == 2)
        #expect(decoded.Blocks[0].BlockIndex == 0)
        #expect(decoded.Blocks[0].BlockToken == "AAABAVahng3S...")
        #expect(decoded.VolumeSize == 100)
        #expect(decoded.BlockSize == 524288)
        #expect(decoded.NextToken == "eyJmaXJzdFRva2VuIjog...")
    }

    @Test("ListSnapshotBlocksResponse round-trips through Codable")
    func listResponseRoundTrip() throws {
        let original = ListSnapshotBlocksResponse(
            Blocks: [
                .init(BlockIndex: 0, BlockToken: "token-0"),
                .init(BlockIndex: 42, BlockToken: "token-42"),
            ],
            ExpiryTime: 1_708_543_200,
            VolumeSize: 100,
            BlockSize: 524_288,
            NextToken: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(
            ListSnapshotBlocksResponse.self,
            from: data
        )
        #expect(decoded == original)
    }

    @Test("EBS block size matches AWS spec (524288)")
    func blockSizeConstant() {
        // AWS documents EBS block size as fixed at 524 288
        // bytes (512 KiB) in
        // `ListSnapshotBlocks`'s `BlockSize` response.
        // Deviating would cascade into the NBD server's
        // export-block-size advertisement.
        #expect(EBSDirectClient.blockSize == 524288)
    }
}

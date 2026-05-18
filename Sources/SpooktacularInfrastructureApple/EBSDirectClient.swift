import Foundation

/// Typed Swift client for AWS's EBS Direct APIs, built on
/// the shared ``HTTPSClient`` + ``SigV4RequestSigner``
/// plumbing so we don't drag in `aws-sdk-swift` (~15 MB build
/// + 400k LOC) for a handful of endpoints.
///
/// ## Supported endpoints (read path)
///
/// Scope for the MVP is read-only — enough to attach a
/// snapshot as a virtual disk to a VM. Write path
/// (`PutSnapshotBlock` + `CompleteSnapshot`) lands in a
/// follow-up so we can roll out the read flow first.
///
/// - [`ListSnapshotBlocks`](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_ebs_ListSnapshotBlocks.html)
///   — paginated enumeration of block indices + per-block
///   tokens. The `BlockToken` is required to actually read
///   the block via `GetSnapshotBlock`.
/// - [`GetSnapshotBlock`](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_ebs_GetSnapshotBlock.html)
///   — returns up to 524 288 bytes (512 KiB) of raw block
///   data, plus `x-amz-Data-Length` + `x-amz-Checksum`
///   response headers. The block size is fixed by AWS — it
///   matches our NBD export block size so no re-chunking
///   is needed.
///
/// ## Credential path (SEP-rooted)
///
/// The `HTTPSClient` is configured with a
/// ``SigV4RequestSigner`` whose `CredentialProvider` is the
/// existing ``KeychainCredentialProvider`` wrapping an STS
/// `AssumeRoleWithWebIdentity` refresher. The OIDC token the
/// refresher submits is signed in the Secure Enclave via
/// `P256KeyStore(service: "oidc-issuer")` — so the root of
/// trust never leaves hardware, STS session creds rotate
/// hourly, and no long-lived AWS access key is stored
/// anywhere.
///
/// ## Error shape
///
/// All failures surface as ``HTTPSError``:
/// - `.status(code: 403, ...)` — credentials denied. Check
///   the IAM role's `ebs:GetSnapshotBlock` permissions.
/// - `.status(code: 404, ...)` — snapshot or block not
///   found. The EBS Direct API returns 404 for any snapshot
///   the caller can't see (expired tokens, region mismatch,
///   cross-account without shared snapshots).
/// - `.status(code: 429, ...)` — throttled. Back off
///   (AWS docs recommend 1s initial, exponential).
public actor EBSDirectClient {

    /// Block size EBS uses on the wire — **512 KiB, fixed**.
    /// Documented under
    /// [ListSnapshotBlocks](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_ebs_ListSnapshotBlocks.html)'s
    /// `BlockSize` response field, which is always
    /// `524288`. Our NBD adapter exposes the same block
    /// size so each NBD read maps to exactly one EBS call.
    public static let blockSize = 524_288

    private let http: any HTTPSClient
    private let endpoint: URL

    /// - Parameters:
    ///   - http: The shared ``HTTPSClient`` configured with
    ///     a ``SigV4RequestSigner`` for the `"ebs"` service
    ///     in the target region.
    ///   - region: AWS region (e.g., `"us-east-1"`). Used
    ///     to construct the regional endpoint.
    public init(http: any HTTPSClient, region: String) {
        self.http = http
        // Per AWS general reference, the EBS Direct endpoint
        // pattern is `ebs.<region>.amazonaws.com`. Gov-cloud
        // regions use `ebs.<region>.amazonaws.com.gov` —
        // add as a secondary case when an operator requests.
        // https://docs.aws.amazon.com/general/latest/gr/ebs-service.html
        self.endpoint = URL(string: "https://ebs.\(region).amazonaws.com")!
    }

    // MARK: - ListSnapshotBlocks

    /// Enumerates all (or a page of) block indices + tokens
    /// for an EBS snapshot.
    ///
    /// - Parameters:
    ///   - snapshotID: `snap-xxxx…` identifier.
    ///   - nextToken: Pagination token from a prior page's
    ///     response; `nil` on the first page.
    ///   - startingBlockIndex: Skip to a specific block index
    ///     (use to resume a partial enumeration).
    ///   - maxResults: Server cap is 10 000; we pass through
    ///     as-is. AWS interprets `nil` as "use server default
    ///     (unspecified)".
    /// - Returns: A typed ``ListSnapshotBlocksResponse``.
    public func listSnapshotBlocks(
        snapshotID: String,
        nextToken: String? = nil,
        startingBlockIndex: Int? = nil,
        maxResults: Int? = nil
    ) async throws -> ListSnapshotBlocksResponse {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.path = "/snapshots/\(snapshotID)/blocks"
        var items: [URLQueryItem] = []
        if let nextToken {
            items.append(URLQueryItem(name: "pageToken", value: nextToken))
        }
        if let startingBlockIndex {
            items.append(URLQueryItem(name: "startingBlockIndex", value: String(startingBlockIndex)))
        }
        if let maxResults {
            items.append(URLQueryItem(name: "maxResults", value: String(maxResults)))
        }
        if !items.isEmpty { components.queryItems = items }

        let request = HTTPSRequest<EmptyBody>(
            .get,
            url: components.url!
        )
        return try await http.send(request, decoding: ListSnapshotBlocksResponse.self)
    }

    // MARK: - GetSnapshotBlock

    /// Reads one 512 KiB block from a snapshot.
    ///
    /// AWS returns the raw block bytes in the response body
    /// (not JSON — this endpoint does not carry a Codable
    /// envelope). Our ``HTTPSClient`` is JSON-first, so we
    /// call the raw `URLSession` transport here rather than
    /// threading a generic "raw bytes" shape through the
    /// typed pipeline.
    ///
    /// - Parameters:
    ///   - snapshotID: `snap-xxxx…` identifier.
    ///   - blockIndex: 0-indexed block position from
    ///     ``listSnapshotBlocks(snapshotID:nextToken:startingBlockIndex:maxResults:)``.
    ///   - blockToken: Opaque per-block token from the same
    ///     list call — expires after ~1 hour so callers
    ///     should re-list before attempting reads on a
    ///     cached plan.
    /// - Returns: The block bytes.
    public func getSnapshotBlock(
        snapshotID: String,
        blockIndex: Int,
        blockToken: String
    ) async throws -> GetSnapshotBlockResponse {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.path = "/snapshots/\(snapshotID)/blocks/\(blockIndex)"
        components.queryItems = [URLQueryItem(name: "blockToken", value: blockToken)]

        let request = HTTPSRequest<EmptyBody>(
            .get,
            url: components.url!
        )
        // Raw-bytes escape hatch on the ``HTTPSClient``
        // protocol — `sendRaw` bypasses JSONDecoder and
        // surfaces the response headers too. AWS puts the
        // data-length + checksum in `x-amz-Data-Length` +
        // `x-amz-Checksum` response headers rather than the
        // body, so preserving headers is the only way to
        // verify the payload.
        let (body, headers) = try await http.sendRaw(request)

        let checksum = headers["x-amz-Checksum"]
            ?? headers["X-Amz-Checksum"]
        let algorithm = headers["x-amz-Checksum-Algorithm"]
            ?? headers["X-Amz-Checksum-Algorithm"]

        return GetSnapshotBlockResponse(
            data: body,
            checksum: checksum,
            checksumAlgorithm: algorithm
        )
    }
}

// MARK: - Request / response DTOs

/// Response for
/// [`ListSnapshotBlocks`](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_ebs_ListSnapshotBlocks.html).
///
/// Field names match the AWS camelCase response format;
/// Codable uses the default strategy.
public struct ListSnapshotBlocksResponse: Sendable, Codable, Equatable {
    public let Blocks: [Block]
    public let ExpiryTime: Double?
    public let VolumeSize: Int64?
    public let BlockSize: Int?
    public let NextToken: String?

    public init(
        Blocks: [Block],
        ExpiryTime: Double? = nil,
        VolumeSize: Int64? = nil,
        BlockSize: Int? = nil,
        NextToken: String? = nil
    ) {
        self.Blocks = Blocks
        self.ExpiryTime = ExpiryTime
        self.VolumeSize = VolumeSize
        self.BlockSize = BlockSize
        self.NextToken = NextToken
    }

    public struct Block: Sendable, Codable, Equatable {
        public let BlockIndex: Int
        public let BlockToken: String

        public init(BlockIndex: Int, BlockToken: String) {
            self.BlockIndex = BlockIndex
            self.BlockToken = BlockToken
        }
    }
}

/// Response shape for ``EBSDirectClient/getSnapshotBlock(snapshotID:blockIndex:blockToken:)``.
public struct GetSnapshotBlockResponse: Sendable {
    /// Raw block bytes — up to 524 288 (512 KiB). Some
    /// blocks may be shorter (last block of a snapshot
    /// smaller than the block size).
    public let data: Data
    /// Base64-encoded `x-amz-Checksum` header value from
    /// AWS. Callers that want integrity assurance should
    /// compute the checksum of `data` and compare.
    public let checksum: String?
    /// Checksum algorithm AWS used. Always `"SHA256"` as of
    /// 2026-04-19.
    public let checksumAlgorithm: String?
}

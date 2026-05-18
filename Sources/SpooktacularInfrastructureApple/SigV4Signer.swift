import Foundation
import CryptoKit

/// AWS SigV4 request signer shared across every adapter that talks
/// to AWS without an SDK.
///
/// Two adapters have historically carried their own near-identical
/// copy of this logic — `S3ObjectLockAuditStore` (audit export) and
/// `DynamoDBDistributedLock` (cross-region lock). Deduplicating
/// keeps them in lockstep on the three places it's easy to drift:
///
/// 1. **Whitespace normalization** of header values (SigV4 §3.2
///    mandates trim + single-space collapse before signing).
/// 2. **Canonical URI encoding** — query and path have different
///    rules, and `URLComponents.percentEncodedQuery` returns
///    something AWS won't accept without further escaping.
/// 3. **Signing-key derivation** — four chained HMAC-SHA256s over
///    the scope elements, in the exact order AWS documents.
///
/// Zero third-party deps: Apple's `CryptoKit` provides SHA256 and
/// HMAC; everything else is Foundation.
///
/// ## Standards
/// - <https://docs.aws.amazon.com/general/latest/gr/signing-aws-api-requests.html>
/// - <https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html>
public struct SigV4Signer: Sendable {

    /// AWS credentials used to sign. Session tokens are optional
    /// and only emitted when populated (STS / instance-profile
    /// flows supply them).
    public struct Credentials: Sendable {
        public let accessKeyID: String
        public let secretAccessKey: String
        public let sessionToken: String?

        public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    public let credentials: Credentials
    public let region: String
    public let service: String

    public init(credentials: Credentials, region: String, service: String) {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    /// Signs a request in place by computing the `Authorization`
    /// header (and, when a session token is present,
    /// `X-Amz-Security-Token`). Callers must have already set the
    /// `X-Amz-Date` header to a value matching `date`; the signer
    /// reads `allHTTPHeaderFields` as its canonical input.
    ///
    /// - Returns: The `Authorization` header value.
    public func signature(for request: URLRequest, body: Data, date: Date) -> String {
        let dateStamp = Self.shortDate(date)
        let amzDateStr = Self.amzDate(date)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        // Canonical headers — trim + collapse-whitespace per §3.2.
        var headers: [(String, String)] = []
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let normalized = value
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            headers.append((key.lowercased(), normalized))
        }
        headers.sort { $0.0 < $1.0 }
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()

        let path = request.url?.path ?? "/"
        let query = request.url?.query ?? ""
        let payloadHash = Self.hex(SHA256.hash(data: body))

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            path,
            query,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDateStr,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        let kDate = Self.hmac(key: Data("AWS4\(credentials.secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = Self.hmac(key: kDate, data: Data(region.utf8))
        let kService = Self.hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmac(key: kService, data: Data("aws4_request".utf8))
        let signature = Self.hex(Self.hmac(key: kSigning, data: Data(stringToSign.utf8)))

        return "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    // MARK: - Formatters (shared, allocation-free after first use)

    /// `X-Amz-Date` header format (`yyyyMMdd'T'HHmmss'Z'`) at UTC.
    public static func amzDate(_ date: Date) -> String {
        Self.amzFormatter.string(from: date)
    }

    /// SigV4 credential-scope date (`yyyyMMdd`) at UTC.
    public static func shortDate(_ date: Date) -> String {
        Self.shortFormatter.string(from: date)
    }

    /// Cached `DateFormatter` for `X-Amz-Date`.
    ///
    /// `DateFormatter` is expensive to allocate and `Sendable`
    /// only once configured, so we keep a single shared instance.
    /// `DateFormatter`'s documented thread-safety on immutable
    /// formatters covers our use case (no mutation after init).
    private static let amzFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Hashing helpers

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

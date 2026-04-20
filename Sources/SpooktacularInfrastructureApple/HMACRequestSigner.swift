import Foundation
import CryptoKit

/// Simple symmetric-HMAC request signer that computes an
/// HMAC-SHA256 of the request body and writes it into a
/// named header. Matches the pattern
/// ``WebhookAuditSink`` already uses for
/// `X-Spooktacular-Audit-Signature`, packaged behind the
/// ``RequestSigner`` protocol so it's reusable for any
/// future webhook or HMAC-authenticated integration.
///
/// This is intentionally **not** a full HTTP-signing
/// standard (no canonicalization, no header signing). It's
/// the minimum viable shape that matches our existing
/// receiver logic; operators who want RFC 9421
/// HTTP-message-signatures can add a sibling signer later.
///
/// ## Apple APIs
///
/// - [`CryptoKit.HMAC<SHA256>`](https://developer.apple.com/documentation/cryptokit/hmac)
///   — hardware-accelerated on Apple Silicon.
public struct HMACRequestSigner: RequestSigner {

    private let key: SymmetricKey
    private let headerName: String

    /// - Parameters:
    ///   - key: Shared symmetric secret. Keep this in
    ///     Keychain, not source; this type holds it in
    ///     memory only.
    ///   - headerName: Header to write the hex digest into.
    ///     Defaults to `"X-Spooktacular-Audit-Signature"` to
    ///     match the existing webhook receiver contract.
    public init(
        key: SymmetricKey,
        headerName: String = "X-Spooktacular-Audit-Signature"
    ) {
        self.key = key
        self.headerName = headerName
    }

    public func sign(_ request: inout URLRequest) async throws {
        let body = request.httpBody ?? Data()
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let hex = Data(mac).map { String(format: "%02x", $0) }.joined()
        request.setValue(hex, forHTTPHeaderField: headerName)
    }
}

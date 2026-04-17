import Foundation
import SpookCore

/// Verifies GitHub webhook signatures using HMAC-SHA256.
///
/// GitHub signs every webhook payload with the repository's webhook secret.
/// The signature is sent in the `X-Hub-Signature-256` header as `sha256=<hex>`.
///
/// ## Wire-format defense
///
/// SHA-256 hex is always **exactly 64 lowercase hex digits**. A
/// shorter string (61, 62, 63 digits, etc.) with a prefix match
/// would collapse the constant-time comparison into a smaller
/// alphabet and give an attacker a tractable brute-force target:
/// only 16^N candidates instead of 16^64. The truncation check
/// below rejects anything that isn't exactly 64 hex digits
/// **before** the comparator runs, so the byte-by-byte compare
/// only ever sees a well-formed expected digest.
///
/// ## Clean Architecture
///
/// This use case depends on ``HMACProvider`` (a port) rather than
/// importing `CryptoKit` directly. The Infrastructure layer provides
/// ``CryptoKitHMACProvider`` as the production implementation.
public enum WebhookSignatureVerifier {

    /// Verifies that a webhook body matches its HMAC-SHA256 signature.
    ///
    /// Uses constant-time comparison to prevent timing attacks. An
    /// empty `secret` is rejected as a configuration error — an
    /// empty key downgrades HMAC to unkeyed SHA-256 and any caller
    /// can forge.
    ///
    /// - Parameters:
    ///   - body: The raw HTTP request body.
    ///   - signature: The `X-Hub-Signature-256` header value (e.g., `sha256=abc123`).
    ///   - secret: The shared webhook secret. Must be non-empty.
    ///   - hmac: The HMAC provider. Defaults to ``CryptoKitHMACProvider``.
    /// - Returns: `true` if the signature is valid.
    public static func verify(
        body: Data,
        signature: String,
        secret: String,
        hmac: any HMACProvider
    ) -> Bool {
        // Refuse empty secrets: HMAC with an empty key reduces to
        // unkeyed SHA-256. Early-return so the audit log shows a
        // rejected request rather than a silent accept.
        guard !secret.isEmpty else { return false }
        guard signature.hasPrefix("sha256=") else { return false }
        let expected = String(signature.dropFirst("sha256=".count))
        // SHA-256 hex is always exactly 64 lowercase hex digits.
        // Anything else — truncated, mixed-case, padded — is
        // rejected before the constant-time comparator runs so a
        // short-prefix attacker can't grind a smaller keyspace.
        guard expected.count == 64 else { return false }
        guard expected.allSatisfy(\.isHexDigit) else { return false }
        let computed = sign(body: body, secret: secret, hmac: hmac)
        guard expected.count == computed.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(expected.utf8, computed.utf8) {
            result |= a ^ b
        }
        return result == 0
    }

    /// Computes the HMAC-SHA256 hex digest for a webhook body.
    ///
    /// - Parameters:
    ///   - body: The raw HTTP request body.
    ///   - secret: The shared webhook secret. Must be non-empty.
    ///   - hmac: The HMAC provider. Defaults to ``CryptoKitHMACProvider``.
    /// - Returns: The lowercase hex-encoded HMAC-SHA256 digest.
    public static func sign(
        body: Data,
        secret: String,
        hmac: any HMACProvider
    ) -> String {
        hmac.hmacSHA256(body: body, secret: secret)
    }
}

import Foundation
import CryptoKit

/// Verifies GitHub webhook signatures using HMAC-SHA256.
///
/// GitHub signs every webhook payload with the repository's webhook secret.
/// The signature is sent in the `X-Hub-Signature-256` header as `sha256=<hex>`.
public enum WebhookSignatureVerifier {

    /// Verifies that a webhook body matches its HMAC-SHA256 signature.
    ///
    /// Uses constant-time comparison to prevent timing attacks.
    ///
    /// - Parameters:
    ///   - body: The raw HTTP request body.
    ///   - signature: The `X-Hub-Signature-256` header value (e.g., `sha256=abc123`).
    ///   - secret: The shared webhook secret.
    /// - Returns: `true` if the signature is valid.
    public static func verify(body: Data, signature: String, secret: String) -> Bool {
        guard signature.hasPrefix("sha256=") else { return false }
        let expected = String(signature.dropFirst("sha256=".count))
        let computed = sign(body: body, secret: secret)
        // Constant-time comparison
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
    ///   - secret: The shared webhook secret.
    /// - Returns: The lowercase hex-encoded HMAC-SHA256 digest.
    public static func sign(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

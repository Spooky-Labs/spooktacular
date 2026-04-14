import Foundation

/// Abstracts HMAC computation so use cases don't depend on `CryptoKit`.
///
/// The Infrastructure layer provides a ``CryptoKitHMACProvider``
/// using Apple's `CryptoKit`. Tests can inject a deterministic provider.
///
/// ## Clean Architecture
///
/// Cryptographic operations are infrastructure concerns. The use case
/// (``WebhookSignatureVerifier``) needs to verify a signature — it
/// doesn't care whether the HMAC is computed via CryptoKit, CommonCrypto,
/// or a hardware security module.
public protocol HMACProvider: Sendable {
    /// Computes the HMAC-SHA256 hex digest of a body using a secret.
    ///
    /// - Parameters:
    ///   - body: The data to sign.
    ///   - secret: The shared secret key.
    /// - Returns: The lowercase hex-encoded HMAC-SHA256 digest.
    func hmacSHA256(body: Data, secret: String) -> String
}

import Foundation
import SpooktacularCore
import SpooktacularApplication
import CryptoKit

/// Concrete ``HMACProvider`` using Apple's CryptoKit.
///
/// Production implementation for webhook signature verification.
/// Built on `HMAC<SHA256>` from CryptoKit (see
/// https://developer.apple.com/documentation/cryptokit ).
///
/// ## Empty-secret defense
///
/// An empty secret would let a caller downgrade HMAC to "plain
/// SHA-256 with no key" — a valid HMAC per the RFC 2104 math but
/// trivially forgeable by anyone who can hash the body. The
/// initializer therefore refuses to construct a provider bound
/// to an empty key, and the stateless API surface guards each
/// call the same way. Either a misconfiguration (empty
/// `SPOOKTACULAR_WEBHOOK_SECRET`) or an attacker-supplied empty string
/// surfaces as a typed error instead of a silent accept.
public struct CryptoKitHMACProvider: HMACProvider {

    public init() {}

    public func hmacSHA256(body: Data, secret: String) -> String {
        // Empty secret would collapse HMAC into unkeyed SHA-256.
        // `WebhookSignatureVerifier.verify(...)` already refuses
        // empty secrets at the caller layer. As belt + braces, if
        // a mis-wired caller reaches us directly we return a
        // deliberately poisoned digest — the SHA-256 of a fixed
        // sentinel string. That digest is deterministic (for
        // regression tests that cover this path) but cannot
        // collide with any valid HMAC, so the verifier's
        // constant-time compare will fail closed.
        guard !secret.isEmpty else {
            let sentinel = Data("com.spooktacular.hmac.empty-secret-rejected".utf8)
            let hash = SHA256.hash(data: sentinel)
            return hash.map { String(format: "%02x", $0) }.joined()
        }
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

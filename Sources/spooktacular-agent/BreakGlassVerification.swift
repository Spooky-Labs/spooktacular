import Foundation
import CryptoKit
import SpookCore
import SpookApplication

/// Agent-side verifier for break-glass tickets.
///
/// Lives in the guest-agent target (not in the host-side
/// `SpookInfrastructureApple` codec module) so the agent binary
/// stays minimal: it pulls in `SpookCore` for the
/// ``BreakGlassTicket`` value type and `SpookApplication` for
/// ``UsedTicketCache``, but NOT the full Apple-infrastructure
/// stack (HTTP server, TLS, audit sinks) that only the host needs.
///
/// The wire format and signature algorithm are fixed:
///
/// - Wire: `bgt:<base64url-payload>.<base64url-signature>`
/// - Signature: **P-256 ECDSA** over the canonical-JSON payload
///   bytes, 64-byte raw (r ‖ s) representation
/// - No `alg` header — eliminates JWT's algorithm-confusion
///   attack surface per OWASP JWT Cheat Sheet
///
/// ## Trust model — allowlist, not single key
///
/// Each operator generates their own Secure-Enclave-bound P-256
/// key on their own workstation. The fleet's agents trust the
/// **union** of those operators' public keys: a ticket verifies
/// if any one of the allowlisted keys accepted the signature.
/// This model gives two properties the prior single-shared-key
/// design did not:
///
/// - **Non-repudiation**: a successful signature cryptographically
///   attributes the ticket to a specific operator's hardware key.
///   The `issuer` claim is no longer a self-asserted string — it
///   is bound to the key that produced the signature.
/// - **Offboarding without fleet rotation**: removing an operator
///   is a single `.pem` delete from the agent's trust directory;
///   every other operator's credentials keep working.
public final class BreakGlassTicketVerifier: @unchecked Sendable {

    private let publicKeys: [P256.Signing.PublicKey]
    private let allowedIssuers: Set<String>
    private let cache: UsedTicketCache
    private let tenant: TenantID
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - publicKeys: Allowlist of trusted operator public
    ///     keys. A ticket verifies if its signature matches any
    ///     of these; the first match wins. Typically loaded
    ///     from a directory of PEM-encoded public keys.
    ///   - allowedIssuers: Operator-approved issuer identities.
    ///     A ticket whose `issuer` claim isn't on this allowlist
    ///     is rejected. Defeats the "attacker has a valid key
    ///     + mints their own ticket" attack.
    ///   - tenant: The agent's own tenant. Tickets minted for a
    ///     different tenant fail verification — cross-tenant
    ///     replay is the attack this field closes.
    ///   - cache: Shared single-use denylist. Usually one per
    ///     agent process.
    public init(
        publicKeys: [P256.Signing.PublicKey],
        allowedIssuers: Set<String>,
        tenant: TenantID,
        cache: UsedTicketCache
    ) {
        self.publicKeys = publicKeys
        self.allowedIssuers = allowedIssuers
        self.tenant = tenant
        self.cache = cache
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    /// Result of verification. Distinct cases so the caller can
    /// audit differently for "expired" (operator-facing retry
    /// signal) vs "invalid" (security-relevant).
    public enum VerifyResult: Sendable {
        case success(BreakGlassTicket)
        case failure(BreakGlassTicketError)
    }

    /// Verifies a `bgt:`-prefixed token end-to-end:
    ///
    /// 1. Envelope shape (`bgt:<b64>.<b64>`)
    /// 2. Signature over the payload bytes (P-256 ECDSA,
    ///    allowlist of pinned keys — accept if any match)
    /// 3. Typed claim decode
    /// 4. Issuer ∈ allowlist
    /// 5. Tenant matches this agent's tenant
    /// 6. Not expired, not too-future (`issuedAt` skew)
    /// 7. `maxUses` within a reasonable bound
    /// 8. Atomic consume via `UsedTicketCache` — the second
    ///    caller with the same JTI gets `.alreadyConsumed`
    ///
    /// OWASP-aligned order: signature FIRST, then claim decode,
    /// then allowlist / temporal / single-use.
    public func verify(ticket raw: String) -> VerifyResult {
        guard !publicKeys.isEmpty else {
            return .failure(.invalidTicket)
        }
        guard raw.hasPrefix(BreakGlassTicket.wirePrefix) else {
            return .failure(.malformedEnvelope)
        }
        let body = String(raw.dropFirst(BreakGlassTicket.wirePrefix.count))
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .failure(.malformedEnvelope)
        }
        guard let payload = Self.base64URLDecode(String(parts[0])),
              let signatureBytes = Self.base64URLDecode(String(parts[1])) else {
            return .failure(.malformedEnvelope)
        }

        // P-256 raw signatures are exactly 64 bytes (r ‖ s).
        guard signatureBytes.count == 64 else {
            return .failure(.invalidTicket)
        }
        let ecdsa: P256.Signing.ECDSASignature
        do {
            ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        } catch {
            return .failure(.invalidTicket)
        }

        let signatureValid = publicKeys.contains { key in
            key.isValidSignature(ecdsa, for: payload)
        }
        guard signatureValid else {
            return .failure(.invalidTicket)
        }

        let t: BreakGlassTicket
        do {
            t = try decoder.decode(BreakGlassTicket.self, from: payload)
        } catch {
            return .failure(.invalidTicket)
        }

        guard allowedIssuers.contains(t.issuer) else {
            return .failure(.invalidTicket)
        }
        guard t.tenant == tenant else {
            return .failure(.invalidTicket)
        }
        if t.isExpired() || t.isNotYetValid() {
            return .failure(.expired)
        }
        guard t.maxUses >= 1, t.maxUses <= 100 else {
            return .failure(.invalidTicket)
        }

        // Single-use (or capped-use) enforcement. This is where
        // two concurrent requests with the same JTI are
        // linearized into exactly one success.
        guard cache.tryConsume(
            jti: t.jti,
            expiresAt: t.expiresAt,
            maxUses: t.maxUses
        ) else {
            return .failure(.alreadyConsumed)
        }
        return .success(t)
    }

    // MARK: - base64url (RFC 4648 §5)

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

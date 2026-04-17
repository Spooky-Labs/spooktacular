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
/// - Signature: **Ed25519** over the canonical-JSON payload bytes
/// - No `alg` header — eliminates JWT's algorithm-confusion
///   attack surface per OWASP JWT Cheat Sheet
///
/// Every verification path is constant-time in the signature
/// check (CryptoKit's `Curve25519.Signing.PublicKey.isValidSignature`
/// is documented as constant-time). Error reporting is coarse
/// (`.invalidTicket` for every non-expiry failure) to avoid an
/// oracle that leaks which check failed.
public final class BreakGlassTicketVerifier: @unchecked Sendable {

    private let publicKey: Curve25519.Signing.PublicKey
    private let allowedIssuers: Set<String>
    private let cache: UsedTicketCache
    private let tenant: TenantID
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - publicKey: Ed25519 public key the agent pins. Tickets
    ///     signed by any other key are rejected even when they're
    ///     otherwise well-formed.
    ///   - allowedIssuers: Operator-approved issuer identities.
    ///     A ticket whose `issuer` claim isn't on the allowlist
    ///     is rejected — defeats the "attacker has their own
    ///     valid Ed25519 key + mints their own ticket" attack.
    ///   - tenant: The agent's own tenant. Tickets for a
    ///     different tenant fail verification — cross-tenant
    ///     replay is the specific attack this field closes.
    ///   - cache: Shared single-use denylist. Usually one per
    ///     agent process.
    public init(
        publicKey: Curve25519.Signing.PublicKey,
        allowedIssuers: Set<String>,
        tenant: TenantID,
        cache: UsedTicketCache
    ) {
        self.publicKey = publicKey
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
    /// 2. Signature over the payload bytes (Ed25519, pinned key)
    /// 3. Typed claim decode
    /// 4. Issuer ∈ allowlist
    /// 5. Tenant matches this agent's tenant
    /// 6. Not expired, not too-future (`issuedAt` skew)
    /// 7. `maxUses` within a reasonable bound
    /// 8. Atomic consume via `UsedTicketCache` — the second
    ///    caller with the same JTI gets `.alreadyConsumed`
    ///
    /// OWASP-aligned order: signature FIRST, then claim decode,
    /// then allowlist/temporal/single-use. "Verify the signature
    /// before trusting any of the claims" is the rule most
    /// exploited JWT libraries fail.
    public func verify(ticket raw: String) -> VerifyResult {
        guard raw.hasPrefix(BreakGlassTicket.wirePrefix) else {
            return .failure(.malformedEnvelope)
        }
        let body = String(raw.dropFirst(BreakGlassTicket.wirePrefix.count))
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .failure(.malformedEnvelope)
        }
        guard let payload = Self.base64URLDecode(String(parts[0])),
              let signature = Self.base64URLDecode(String(parts[1])) else {
            return .failure(.malformedEnvelope)
        }

        guard publicKey.isValidSignature(signature, for: payload) else {
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

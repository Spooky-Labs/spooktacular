import Foundation

/// A time-limited, single-use credential for emergency (break-glass)
/// access to operator-tier guest-agent endpoints.
///
/// Break-glass is a documented control pattern — NIST SP 800-53
/// AC-14, OWASP ASVS V2.10, SOC 2 CC6.6, ISO 27001 A.9.2.3 all
/// require an emergency-access path that is audit-traceable,
/// time-bounded, and separate from everyday admin credentials.
///
/// Spooktacular's prior break-glass mechanism used long-lived
/// static tokens stored in the Keychain. That satisfied the
/// "separate credential" requirement but failed on the
/// "time-bounded" and "single-use" properties OWASP's JWT Cheat
/// Sheet + ASVS V3.3.3 (session inactivity timeout) both call
/// out. A `BreakGlassTicket` adds both guarantees:
///
/// - **Time-bounded**: `expiresAt` is a hard ceiling; tickets
///   older than `expiresAt + 60s` (clock skew) are rejected.
/// - **Single-use (by default)**: `maxUses` defaults to 1 and is
///   enforced by `UsedTicketCache` — the second consume of the
///   same JTI fails even if the signature is still valid.
/// - **Unforgeable**: Ed25519 signature over the canonical JSON
///   bytes. Signing key rotation is an operator-scheduled event;
///   compromised tickets are revoked via the used-JTI cache.
/// - **Auditable**: JTI, issuer, tenant, and optional `reason`
///   land in the `AuditRecord` emitted on both issuance and
///   consumption, giving a reviewer a 1-to-1 correspondence
///   between "ticket minted" and "ticket used."
///
/// ## Wire format
///
/// Tickets are serialized as `bgt:<base64url(payload)>.<base64url(sig)>`
/// — compact like a JWT but **without** the JWT header. OWASP's
/// JWT Cheat Sheet §"Explicitly use only one algorithm" recommends
/// pinning the signing algorithm at verification time. We go a
/// step further and omit `alg` entirely: the `bgt:` prefix is the
/// only type tag, and verification is hard-coded to Ed25519. An
/// attacker who substitutes `{"alg":"none"}` has no header to
/// substitute into.
///
/// ## OWASP mapping
///
/// | OWASP control | Field / behavior |
/// |---------------|------------------|
/// | "Use an approved algorithm" | Ed25519 (RFC 8037, ASVS V6.2) |
/// | "Reject none / algorithm confusion" | No `alg` header — surface eliminated |
/// | "Sufficient JTI entropy" | 128-bit UUIDv4 |
/// | "Short-lived tokens" | `expiresAt` enforced; codec caps TTL at 1h |
/// | "Validate `exp` / `nbf` / `iss` / `aud`" | All four verified |
/// | "Implement denylist" | `UsedTicketCache` |
/// | "Audit every use" | Emitted at issue + consume |
/// | "Clock skew tolerance" | Symmetric 60s window |
public struct BreakGlassTicket: Sendable, Codable, Equatable {

    /// Wire-format prefix that disambiguates break-glass ticket
    /// bearers from static Bearer tokens. Hoisted into SpookCore
    /// (rather than the codec's module) so any target — including
    /// the minimal guest-agent binary — can cheaply recognize a
    /// ticket-shaped header without pulling in CryptoKit or the
    /// rest of the infrastructure stack.
    public static let wirePrefix = "bgt:"

    /// Unique ticket identifier — 128 bits of entropy from
    /// `UUID()` via `SystemRandomNumberGenerator`. Used as the
    /// denylist key for single-use enforcement and as the
    /// correlation ID on audit records. OWASP recommends ≥ 64
    /// bits; 128 is the JWT Best-Current-Practice minimum.
    public let jti: String

    /// Identity that issued this ticket (typically an operator
    /// username or service-account ID). Agents enforce an issuer
    /// allowlist before accepting a ticket — defeats the
    /// "attacker signs their own ticket with their own key"
    /// attack even when the attacker has a valid Ed25519 key.
    public let issuer: String

    /// Tenant this ticket scopes access to. Checked against the
    /// request's tenant context; a ticket minted for tenant A
    /// can't be replayed against tenant B even within the
    /// validity window.
    public let tenant: TenantID

    /// Wall-clock time the ticket was issued. Used for audit
    /// correlation; the validator rejects tickets with
    /// `issuedAt > now + clockSkew` (operator clock ahead).
    public let issuedAt: Date

    /// Wall-clock time after which the ticket is invalid, even
    /// if `maxUses` has remaining capacity. Capped at 1 hour
    /// from `issuedAt` by the codec — operators who want
    /// longer-lived credentials are explicitly using the wrong
    /// primitive and should rotate static tokens instead.
    public let expiresAt: Date

    /// Maximum number of times this ticket may be consumed.
    /// Defaults to 1 for strict single-use — an incident
    /// response needing multiple API calls should issue
    /// separate tickets, so each call carries a distinct
    /// audit record.
    public let maxUses: Int

    /// Optional human-readable reason surfaced in every audit
    /// record. Not cryptographically binding — an attacker in
    /// possession of a ticket can still use it — but a clear
    /// audit signal: "alice@corp used a break-glass ticket at
    /// 3:07am, reason: `runner-17 stuck in draining`."
    public let reason: String?

    public init(
        jti: String,
        issuer: String,
        tenant: TenantID,
        issuedAt: Date,
        expiresAt: Date,
        maxUses: Int = 1,
        reason: String? = nil
    ) {
        self.jti = jti
        self.issuer = issuer
        self.tenant = tenant
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.reason = reason
    }

    /// True when `now` is past `expiresAt + clockSkew`. Callers
    /// should also check `!isFutureIssued(...)` for pre-activation
    /// attempts.
    public func isExpired(now: Date = Date(), clockSkew: TimeInterval = 60) -> Bool {
        now > expiresAt.addingTimeInterval(clockSkew)
    }

    /// True when `issuedAt` is in the future beyond the skew
    /// tolerance — indicates a clock-skew or replay-before-issue
    /// attack. Symmetrically named alongside ``isExpired(now:clockSkew:)``:
    /// one asks "past end" and one asks "issued in the future."
    ///
    /// The verification condition is
    /// `issuedAt > now + clockSkew` — i.e., reject when the
    /// minting host's clock ran more than `clockSkew` seconds
    /// ahead of the verifying host's clock.
    public func isFutureIssued(now: Date = Date(), clockSkew: TimeInterval = 60) -> Bool {
        issuedAt > now.addingTimeInterval(clockSkew)
    }
}

// MARK: - Errors

/// Errors produced during break-glass ticket operations.
///
/// Every case carries a `recoverySuggestion` so the CLI can
/// render an actionable message. Deliberately coarse-grained
/// for the verify path — an attacker probing the validator
/// should see the same error for "wrong signature" vs "wrong
/// issuer" to avoid an information oracle.
public enum BreakGlassTicketError: Error, LocalizedError, Sendable, Equatable {
    /// The envelope doesn't look like a `bgt:` ticket.
    case malformedEnvelope

    /// Signature verification failed, OR any other verification
    /// step failed. Intentionally conflated to prevent leaking
    /// which validation step rejected the ticket.
    case invalidTicket

    /// Ticket expired or not yet valid.
    case expired

    /// Ticket's `maxUses` is exhausted.
    case alreadyConsumed

    /// TTL in the issuance path exceeded the policy maximum.
    case ttlTooLong(maximum: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .malformedEnvelope:
            "The break-glass ticket is not a valid `bgt:<base64>.<base64>` envelope."
        case .invalidTicket:
            "The break-glass ticket failed verification."
        case .expired:
            "The break-glass ticket has expired or is not yet valid."
        case .alreadyConsumed:
            "The break-glass ticket has already been consumed."
        case .ttlTooLong(let max):
            "Requested TTL exceeds the policy maximum of \(Int(max / 60)) minutes."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .malformedEnvelope:
            "Tickets begin with `bgt:` followed by a base64url payload, a `.`, and a base64url signature."
        case .invalidTicket:
            "Verify the signing key on the issuer matches the public key this agent is configured with, and that the issuer is on the agent's allowlist."
        case .expired:
            "Issue a new ticket with `spook break-glass issue` and use it within the TTL."
        case .alreadyConsumed:
            "Each ticket is single-use by default. Issue a new one."
        case .ttlTooLong:
            "Emergency access should be narrow in time. Issue a shorter-TTL ticket and re-issue if the incident extends."
        }
    }
}

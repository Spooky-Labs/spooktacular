import Foundation
import CryptoKit
import SpookCore

/// Serializes and verifies ``BreakGlassTicket`` values to the
/// compact `bgt:<base64url-payload>.<base64url-signature>`
/// wire format.
///
/// Deliberately **not** a JWT:
///
/// - No `alg` header — the `bgt:` prefix is the only type tag,
///   and verification is hard-coded to Ed25519. OWASP's JWT
///   Cheat Sheet §"Explicitly use only one algorithm" treats
///   algorithm pinning at verification as the gold standard;
///   omitting the header eliminates the attack surface entirely.
/// - Canonical JSON encoding (`.sortedKeys`) — the signed bytes
///   are the same on every host, so a minted ticket signed on
///   host A verifies on host B without ambiguity.
/// - 1-hour maximum TTL enforced at issuance — OWASP
///   §"Short-lived tokens" and NIST SP 800-63B §5.1.9.1 both
///   cap emergency credentials aggressively. Operators who
///   want longer-lived access are using the wrong primitive.
///
/// ## Key material
///
/// The `signingKey` passed to `encode` is an Ed25519 private
/// key. The matching public key is pinned on every agent that
/// verifies tickets. Key rotation is an operator-scheduled
/// ceremony — there is no online key-exchange path; compromised
/// keys are rotated by replacing both halves + re-issuing any
/// in-flight tickets.
public enum BreakGlassTicketCodec {

    /// The wire-format prefix. Rejected as "not a break-glass
    /// ticket" if the input doesn't start with this, so callers
    /// can cheaply distinguish between static tokens and
    /// tickets on the authorization header.
    public static let prefix = "bgt:"

    /// Policy ceiling on ticket TTL. OWASP recommends short
    /// lifetimes for emergency credentials; one hour is the
    /// widely-cited upper bound for break-glass sessions.
    public static let maxTTL: TimeInterval = 3600

    /// Canonical JSON encoder — `.sortedKeys` + ISO-8601 dates
    /// so the same logical ticket has the same byte sequence
    /// on every host. Required for signature stability.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Encode

    /// Signs and serializes a ticket. Throws ``BreakGlassTicketError/ttlTooLong``
    /// if `expiresAt - issuedAt` exceeds ``maxTTL``.
    public static func encode(
        _ ticket: BreakGlassTicket,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let ttl = ticket.expiresAt.timeIntervalSince(ticket.issuedAt)
        guard ttl > 0, ttl <= maxTTL else {
            throw BreakGlassTicketError.ttlTooLong(maximum: maxTTL)
        }

        let payload = try encoder.encode(ticket)
        let signature = try signingKey.signature(for: payload)
        return prefix
            + base64URLEncode(payload)
            + "."
            + base64URLEncode(Data(signature))
    }

    // MARK: - Decode + verify

    /// Decodes and verifies a ticket. Returns the parsed ticket
    /// if and only if:
    ///
    /// 1. The envelope starts with `bgt:` and has exactly one
    ///    `.` separator.
    /// 2. Both base64url segments decode cleanly.
    /// 3. The signature verifies against `publicKey`.
    /// 4. `issuer` is in `allowedIssuers`.
    /// 5. The ticket is neither expired nor not-yet-valid.
    ///
    /// Most failure modes throw ``BreakGlassTicketError/invalidTicket``
    /// — an intentionally coarse error to prevent oracles from
    /// leaking which check failed. Expiry is distinct because
    /// it's a legitimate retry signal for the caller.
    public static func decode(
        _ raw: String,
        publicKey: Curve25519.Signing.PublicKey,
        allowedIssuers: Set<String>,
        now: Date = Date()
    ) throws -> BreakGlassTicket {
        guard raw.hasPrefix(prefix) else {
            throw BreakGlassTicketError.malformedEnvelope
        }
        let body = String(raw.dropFirst(prefix.count))
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw BreakGlassTicketError.malformedEnvelope
        }
        guard let payloadData = base64URLDecode(String(parts[0])),
              let signatureData = base64URLDecode(String(parts[1])) else {
            throw BreakGlassTicketError.malformedEnvelope
        }

        // Step 1 (OWASP): verify the signature BEFORE decoding
        // the payload. Decoding first + verifying later is the
        // textbook JWT mistake — a malformed-but-trusted claim
        // can influence code paths before the signature check
        // rejects it.
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw BreakGlassTicketError.invalidTicket
        }

        let ticket: BreakGlassTicket
        do {
            ticket = try decoder.decode(BreakGlassTicket.self, from: payloadData)
        } catch {
            throw BreakGlassTicketError.invalidTicket
        }

        // Issuer allowlist — defeats the "attacker with their
        // own Ed25519 key mints a ticket" attack. Signature
        // validity is necessary but not sufficient; the issuer
        // must be in the operator-approved set.
        guard allowedIssuers.contains(ticket.issuer) else {
            throw BreakGlassTicketError.invalidTicket
        }

        if ticket.isExpired(now: now) || ticket.isNotYetValid(now: now) {
            throw BreakGlassTicketError.expired
        }

        // Reject absurd maxUses — protects the cache from DoS
        // via a valid-signed ticket with maxUses = Int.max.
        guard ticket.maxUses >= 1, ticket.maxUses <= 100 else {
            throw BreakGlassTicketError.invalidTicket
        }

        return ticket
    }

    // MARK: - base64url (RFC 4648 §5)

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

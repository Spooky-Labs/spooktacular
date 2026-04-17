import Foundation
import CryptoKit
import SpookApplication
import SpookCore

/// Type alias retained for readability at break-glass call
/// sites; the primitive is the shared ``P256Signer``.
public typealias BreakGlassSigner = P256Signer

/// Serializes and verifies ``BreakGlassTicket`` values to the
/// compact `bgt:<base64url-payload>.<base64url-signature>`
/// wire format.
///
/// Deliberately **not** a JWT:
///
/// - No `alg` header — the `bgt:` prefix is the only type tag,
///   and verification is hard-coded to P-256 ECDSA. OWASP's JWT
///   Cheat Sheet §"Explicitly use only one algorithm" treats
///   algorithm pinning at verification as the gold standard;
///   omitting the header eliminates the attack surface entirely.
/// - Canonical JSON encoding (`.sortedKeys`) — the signed bytes
///   are the same on every host, so a minted ticket signed on
///   host A verifies on host B without ambiguity.
/// - 1-hour maximum TTL enforced at issuance.
///
/// ## Why P-256 (and not Ed25519)
///
/// Ed25519 is cryptographically equivalent to P-256 ECDSA for
/// this use case and has nicer properties in isolation
/// (deterministic signatures, no nonce-reuse risk in the naive
/// software implementation). We use P-256 here specifically
/// because the macOS Secure Enclave supports exactly P-256 for
/// asymmetric operations and **does not** support Ed25519. The
/// hardware-bound signing that closes OWASP ASVS V2.7 is only
/// achievable via P-256 on Apple platforms. The SEP handles
/// nonce generation correctly (per Apple's documentation) so
/// the classical ECDSA nonce-reuse concern is inapplicable.
///
/// ## Key material
///
/// An operator's signing key is generated inside the Secure
/// Enclave on their workstation — see
/// ``BreakGlassSigningKeyStore``. The matching public key is
/// exported as PEM SPKI and added to the fleet's trust
/// allowlist (one public key per operator). Agents iterate the
/// allowlist on verify and accept the first match.
public enum BreakGlassTicketCodec {

    /// The wire-format prefix. Hoisted to ``BreakGlassTicket/wirePrefix``
    /// so non-codec targets (guest agent, CLI shells) can
    /// disambiguate tickets from static Bearer tokens without
    /// importing this module.
    public static var prefix: String { BreakGlassTicket.wirePrefix }

    /// Policy ceiling on ticket TTL.
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

    /// Signs and serializes a ticket. Throws
    /// ``BreakGlassTicketError/ttlTooLong`` if
    /// `expiresAt - issuedAt` exceeds ``maxTTL``.
    public static func encode(
        _ ticket: BreakGlassTicket,
        signer: any BreakGlassSigner
    ) throws -> String {
        let ttl = ticket.expiresAt.timeIntervalSince(ticket.issuedAt)
        guard ttl > 0, ttl <= maxTTL else {
            throw BreakGlassTicketError.ttlTooLong(maximum: maxTTL)
        }

        let payload = try encoder.encode(ticket)
        let signature = try signer.signature(for: payload)
        return prefix
            + base64URLEncode(payload)
            + "."
            + base64URLEncode(signature)
    }

    // MARK: - Decode + verify

    /// Decodes and verifies a ticket against a trust allowlist
    /// of operator public keys. Returns the parsed ticket if
    /// and only if:
    ///
    /// 1. The envelope starts with `bgt:` and has exactly one
    ///    `.` separator.
    /// 2. Both base64url segments decode cleanly.
    /// 3. The signature verifies against **at least one** key
    ///    in `publicKeys`.
    /// 4. `issuer` is in `allowedIssuers`.
    /// 5. The ticket is neither expired nor not-yet-valid.
    /// 6. `maxUses` is within policy bounds.
    ///
    /// Signature verification is OWASP step-1: we check it
    /// *before* decoding the payload so a malformed-but-trusted
    /// claim cannot influence code paths.
    ///
    /// Most failure modes throw
    /// ``BreakGlassTicketError/invalidTicket`` — an intentionally
    /// coarse error to prevent oracles from leaking which check
    /// failed. Expiry is distinct because it's a legitimate
    /// retry signal for the caller.
    public static func decode(
        _ raw: String,
        publicKeys: [P256.Signing.PublicKey],
        allowedIssuers: Set<String>,
        now: Date = Date()
    ) throws -> BreakGlassTicket {
        guard !publicKeys.isEmpty else {
            throw BreakGlassTicketError.invalidTicket
        }
        // Envelope shape validation — every violation surfaces as
        // `malformedEnvelope` but the internal narrative stays
        // specific via the comment trail below.
        //
        // 1. Prefix must be exactly `bgt:`.
        // 2. After stripping the prefix, exactly one `.` splits
        //    the body into two base64url segments.
        // 3. Each segment must decode as valid base64url (RFC 4648
        //    §5). Empty or ill-padded segments are rejected.
        guard raw.hasPrefix(prefix) else {
            throw BreakGlassTicketError.malformedEnvelope
        }
        let body = String(raw.dropFirst(prefix.count))
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw BreakGlassTicketError.malformedEnvelope
        }
        let payloadB64 = String(parts[0])
        let signatureB64 = String(parts[1])
        guard !payloadB64.isEmpty, !signatureB64.isEmpty else {
            throw BreakGlassTicketError.malformedEnvelope
        }
        guard let payloadData = base64URLDecode(payloadB64),
              let signatureData = base64URLDecode(signatureB64) else {
            throw BreakGlassTicketError.malformedEnvelope
        }

        // P-256 raw signatures are exactly 64 bytes (r ‖ s).
        // Reject anything else before we even attempt verification.
        guard signatureData.count == 64 else {
            throw BreakGlassTicketError.invalidTicket
        }
        let ecdsa: P256.Signing.ECDSASignature
        do {
            ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        } catch {
            throw BreakGlassTicketError.invalidTicket
        }

        // Try each trusted key until one accepts the signature.
        // For a small roster (typically < 10 operators) this is
        // cheap and avoids the complexity of embedding a key-id
        // in the wire format.
        let signatureValid = publicKeys.contains { key in
            key.isValidSignature(ecdsa, for: payloadData)
        }
        guard signatureValid else {
            throw BreakGlassTicketError.invalidTicket
        }

        let ticket: BreakGlassTicket
        do {
            ticket = try decoder.decode(BreakGlassTicket.self, from: payloadData)
        } catch {
            throw BreakGlassTicketError.invalidTicket
        }

        guard allowedIssuers.contains(ticket.issuer) else {
            throw BreakGlassTicketError.invalidTicket
        }

        if ticket.isExpired(now: now) || ticket.isFutureIssued(now: now) {
            throw BreakGlassTicketError.expired
        }

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

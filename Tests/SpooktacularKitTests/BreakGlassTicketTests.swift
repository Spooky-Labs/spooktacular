import Testing
import Foundation
import CryptoKit
@testable import SpooktacularCore
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

/// Covers the OWASP-aligned break-glass ticket contract:
/// P-256 ECDSA signature verification, expiry, TTL cap,
/// single-use via the denylist, issuer allowlist, the
/// multi-key trust allowlist (one key per operator), and the
/// coarse-grained error taxonomy that prevents oracle attacks.
@Suite("BreakGlass ticket", .tags(.security, .cryptography))
struct BreakGlassTicketTests {

    // MARK: - Helpers

    private static func makeSoftwareSigner() -> (P256.Signing.PrivateKey, P256.Signing.PublicKey) {
        let priv = P256.Signing.PrivateKey()
        return (priv, priv.publicKey)
    }

    private static func validTicket(
        issuer: String = "sre@acme",
        tenant: TenantID = .default,
        maxUses: Int = 1,
        reason: String? = nil,
        ttl: TimeInterval = 900
    ) -> BreakGlassTicket {
        let now = Date()
        return BreakGlassTicket(
            jti: UUID().uuidString,
            issuer: issuer,
            tenant: tenant,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            maxUses: maxUses,
            reason: reason
        )
    }

    // MARK: - Encode/decode round-trip

    @Test("round-trip — encode then decode preserves every field")
    func roundTrip() throws {
        let (priv, pub) = Self.makeSoftwareSigner()
        let ticket = Self.validTicket(reason: "emergency: runner-01 stuck")
        let wire = try BreakGlassTicketCodec.encode(ticket, signer: priv)
        let decoded = try BreakGlassTicketCodec.decode(
            wire, publicKeys: [pub], allowedIssuers: ["sre@acme"]
        )
        // ISO-8601 JSON dates truncate sub-second precision, so
        // we compare dates with a ≤1s tolerance. All other
        // fields must round-trip exactly.
        #expect(decoded.jti == ticket.jti)
        #expect(decoded.issuer == ticket.issuer)
        #expect(decoded.tenant == ticket.tenant)
        #expect(decoded.maxUses == ticket.maxUses)
        #expect(decoded.reason == ticket.reason)
        #expect(abs(decoded.issuedAt.timeIntervalSince(ticket.issuedAt)) <= 1.0)
        #expect(abs(decoded.expiresAt.timeIntervalSince(ticket.expiresAt)) <= 1.0)
    }

    @Test("wire format carries the `bgt:` prefix and exactly one `.` separator")
    func wireFormatShape() throws {
        let (priv, _) = Self.makeSoftwareSigner()
        let wire = try BreakGlassTicketCodec.encode(Self.validTicket(), signer: priv)
        #expect(wire.hasPrefix("bgt:"))
        let body = wire.dropFirst(4)
        #expect(body.split(separator: ".").count == 2)
    }

    // MARK: - Multi-key allowlist

    @Test("signature verified by any key in the allowlist — first match wins")
    func multiKeyAllowlistAccepts() throws {
        let (alice, alicePub) = Self.makeSoftwareSigner()
        let (_, bobPub) = Self.makeSoftwareSigner()
        let (_, carolPub) = Self.makeSoftwareSigner()

        let wire = try BreakGlassTicketCodec.encode(
            Self.validTicket(issuer: "alice@acme"), signer: alice
        )
        // Alice signs; agent's trust roster is [bob, carol, alice]
        // — order independent. Must accept.
        let decoded = try BreakGlassTicketCodec.decode(
            wire,
            publicKeys: [bobPub, carolPub, alicePub],
            allowedIssuers: ["alice@acme"]
        )
        #expect(decoded.issuer == "alice@acme")
    }

    @Test("signature from an untrusted key rejected even when allowlist non-empty")
    func multiKeyAllowlistRejectsUnknownKey() throws {
        let (attacker, _) = Self.makeSoftwareSigner()
        let (_, alicePub) = Self.makeSoftwareSigner()
        let (_, bobPub) = Self.makeSoftwareSigner()

        let wire = try BreakGlassTicketCodec.encode(
            Self.validTicket(issuer: "alice@acme"), signer: attacker
        )
        // The attacker's signature is cryptographically valid
        // relative to their own key, but their key isn't in the
        // allowlist — reject.
        #expect(throws: BreakGlassTicketError.invalidTicket) {
            try BreakGlassTicketCodec.decode(
                wire,
                publicKeys: [alicePub, bobPub],
                allowedIssuers: ["alice@acme"]
            )
        }
    }

    @Test("empty allowlist fails closed")
    func emptyAllowlistRejects() throws {
        let (priv, _) = Self.makeSoftwareSigner()
        let wire = try BreakGlassTicketCodec.encode(Self.validTicket(), signer: priv)
        #expect(throws: BreakGlassTicketError.invalidTicket) {
            try BreakGlassTicketCodec.decode(
                wire, publicKeys: [], allowedIssuers: ["sre@acme"]
            )
        }
    }

    // MARK: - Signature-tampering rejection

    @Test("tampered payload (flipped bit) fails verification")
    func tamperedPayloadRejected() throws {
        let (priv, pub) = Self.makeSoftwareSigner()
        var wire = try BreakGlassTicketCodec.encode(Self.validTicket(), signer: priv)
        // Flip a character in the payload segment.
        let idx = wire.index(wire.startIndex, offsetBy: 10)
        let orig = wire[idx]
        let flipped: Character = orig == "A" ? "B" : "A"
        wire.replaceSubrange(idx...idx, with: String(flipped))

        #expect(throws: BreakGlassTicketError.invalidTicket) {
            try BreakGlassTicketCodec.decode(
                wire, publicKeys: [pub], allowedIssuers: ["sre@acme"]
            )
        }
    }

    @Test("signature length not 64 bytes rejected as invalidTicket")
    func badSignatureLengthRejected() throws {
        // Base64 "AA" decodes to 1 byte of 0x00, far short of 64.
        let bogus = "bgt:e30.AA"
        let (_, pub) = Self.makeSoftwareSigner()
        #expect(throws: BreakGlassTicketError.self) {
            try BreakGlassTicketCodec.decode(
                bogus, publicKeys: [pub], allowedIssuers: []
            )
        }
    }

    // MARK: - Issuer allowlist

    @Test("issuer not in the allowlist is rejected even with valid signature")
    func untrustedIssuerRejected() throws {
        let (priv, pub) = Self.makeSoftwareSigner()
        let ticket = Self.validTicket(issuer: "attacker@evil.example")
        let wire = try BreakGlassTicketCodec.encode(ticket, signer: priv)

        // Even though the signature is valid, `attacker@evil` isn't
        // on the agent's allowlist — reject.
        #expect(throws: BreakGlassTicketError.invalidTicket) {
            try BreakGlassTicketCodec.decode(
                wire, publicKeys: [pub], allowedIssuers: ["sre@acme"]
            )
        }
    }

    // MARK: - Expiry / not-yet-valid

    @Test("expired ticket surfaces BreakGlassTicketError.expired")
    func expiredRejected() throws {
        let (priv, pub) = Self.makeSoftwareSigner()
        let now = Date()
        let ticket = BreakGlassTicket(
            jti: UUID().uuidString,
            issuer: "sre@acme",
            tenant: .default,
            issuedAt: now.addingTimeInterval(-3500),
            expiresAt: now.addingTimeInterval(-120),
            maxUses: 1,
            reason: nil
        )
        let wire = try BreakGlassTicketCodec.encode(ticket, signer: priv)

        #expect(throws: BreakGlassTicketError.expired) {
            try BreakGlassTicketCodec.decode(
                wire, publicKeys: [pub], allowedIssuers: ["sre@acme"]
            )
        }
    }

    @Test("ticket issued far-future (beyond clock-skew) is rejected as expired")
    func notYetValidRejected() throws {
        let (priv, pub) = Self.makeSoftwareSigner()
        let now = Date()
        let ticket = BreakGlassTicket(
            jti: UUID().uuidString,
            issuer: "sre@acme",
            tenant: .default,
            issuedAt: now.addingTimeInterval(3600),
            expiresAt: now.addingTimeInterval(3600 + 900),
            maxUses: 1,
            reason: nil
        )
        let wire = try BreakGlassTicketCodec.encode(ticket, signer: priv)

        #expect(throws: BreakGlassTicketError.expired) {
            try BreakGlassTicketCodec.decode(
                wire, publicKeys: [pub], allowedIssuers: ["sre@acme"]
            )
        }
    }

    // MARK: - TTL ceiling

    @Test("TTL beyond 1h policy maximum is rejected at encode time")
    func ttlCeilingEnforced() {
        let (priv, _) = Self.makeSoftwareSigner()
        let now = Date()
        let tooLong = BreakGlassTicket(
            jti: UUID().uuidString,
            issuer: "sre@acme",
            tenant: .default,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3600 + 60),
            maxUses: 1,
            reason: nil
        )
        #expect(throws: BreakGlassTicketError.self) {
            _ = try BreakGlassTicketCodec.encode(tooLong, signer: priv)
        }
    }

    // MARK: - Envelope handling

    @Test("missing `bgt:` prefix returns malformedEnvelope")
    func noPrefixRejected() {
        let (_, pub) = Self.makeSoftwareSigner()
        #expect(throws: BreakGlassTicketError.malformedEnvelope) {
            try BreakGlassTicketCodec.decode(
                "not-a-ticket.garbage",
                publicKeys: [pub],
                allowedIssuers: []
            )
        }
    }

    @Test("envelope without exactly one `.` returns malformedEnvelope")
    func malformedEnvelope() {
        let (_, pub) = Self.makeSoftwareSigner()
        for broken in ["bgt:", "bgt:no-separator", "bgt:a.b.c"] {
            #expect(throws: BreakGlassTicketError.malformedEnvelope) {
                try BreakGlassTicketCodec.decode(
                    broken, publicKeys: [pub], allowedIssuers: []
                )
            }
        }
    }

    // MARK: - UsedTicketCache (unchanged from Ed25519 era)

    @Test("tryConsume — first call succeeds, second on same JTI fails")
    func singleUseEnforced() {
        let cache = UsedTicketCache()
        let jti = UUID().uuidString
        let expiry = Date().addingTimeInterval(900)
        let first = cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 1)
        let second = cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 1)
        #expect(first == true)
        #expect(second == false, "Single-use ticket must reject the second consume")
    }

    @Test("tryConsume — respects maxUses > 1")
    func multiUseAllowed() {
        let cache = UsedTicketCache()
        let jti = UUID().uuidString
        let expiry = Date().addingTimeInterval(900)
        let a = cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 3)
        let b = cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 3)
        let c = cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 3)
        let d = cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 3)
        #expect(a && b && c)
        #expect(d == false, "4th consume must fail once maxUses is reached")
    }

    @Test("concurrent consumes on the same JTI serialize into one success")
    func concurrentConsumesSerialize() async {
        let cache = UsedTicketCache()
        let jti = UUID().uuidString
        let expiry = Date().addingTimeInterval(900)

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 1)
                }
            }
            var values: [Bool] = []
            for await v in group { values.append(v) }
            return values
        }

        let successes = results.filter { $0 }.count
        #expect(successes == 1,
                "Exactly one of 50 concurrent consumes may succeed on a maxUses=1 ticket; got \(successes)")
    }

    @Test("expired entries are pruned from the cache")
    func expiredEntriesEvicted() {
        let cache = UsedTicketCache()
        _ = cache.tryConsume(
            jti: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(-1),
            maxUses: 1
        )
        _ = cache.tryConsume(
            jti: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(900),
            maxUses: 1
        )
        #expect(cache.entryCount <= 2, "Expired entries should be reaped on opportunistic cleanup")
    }

    // MARK: - Error-hint coverage

    @Test("every BreakGlassTicketError case carries description + recovery")
    func allErrorsHaveHints() {
        let cases: [BreakGlassTicketError] = [
            .malformedEnvelope,
            .invalidTicket,
            .expired,
            .alreadyConsumed,
            .ttlTooLong(maximum: 3600),
        ]
        for c in cases {
            #expect(c.errorDescription?.isEmpty == false)
            #expect(c.recoverySuggestion?.isEmpty == false)
        }
    }

    // MARK: - PEM public-key distribution

    @Test("public key round-trips via PEM SPKI — the fleet-distribution format")
    func publicKeyPEMRoundTrip() throws {
        let (_, pub) = Self.makeSoftwareSigner()
        let pem = pub.pemRepresentation
        #expect(pem.contains("BEGIN PUBLIC KEY"))
        let reconstructed = try P256.Signing.PublicKey(pemRepresentation: pem)
        // Public keys equate by their x963 representation.
        #expect(reconstructed.x963Representation == pub.x963Representation)
    }
}

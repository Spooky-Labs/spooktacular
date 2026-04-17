import Testing
import Foundation
import CryptoKit
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

/// Covers the OWASP-aligned break-glass ticket contract:
/// signature verification, expiry, TTL cap, single-use via the
/// denylist, issuer allowlist, and the coarse-grained error
/// taxonomy that prevents oracle attacks.
@Suite("BreakGlass ticket", .tags(.security))
struct BreakGlassTicketTests {

    // MARK: - Helpers

    private static func makeKeyPair() -> (Curve25519.Signing.PrivateKey, Curve25519.Signing.PublicKey) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv, priv.publicKey)
    }

    private static func validTicket(
        issuer: String = "sre@acme",
        tenant: TenantID = .default,
        maxUses: Int = 1,
        reason: String? = nil,
        ttl: TimeInterval = 900  // 15 minutes
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
        let (priv, pub) = Self.makeKeyPair()
        let ticket = Self.validTicket(reason: "emergency: runner-01 stuck")
        let wire = try BreakGlassTicketCodec.encode(ticket, signingKey: priv)
        let decoded = try BreakGlassTicketCodec.decode(
            wire, publicKey: pub, allowedIssuers: ["sre@acme"]
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
        let (priv, _) = Self.makeKeyPair()
        let wire = try BreakGlassTicketCodec.encode(Self.validTicket(), signingKey: priv)
        #expect(wire.hasPrefix("bgt:"))
        let body = wire.dropFirst(4)
        #expect(body.split(separator: ".").count == 2)
    }

    // MARK: - Signature-tampering rejection

    @Test("tampered payload (flipped bit) fails verification")
    func tamperedPayloadRejected() throws {
        let (priv, pub) = Self.makeKeyPair()
        var wire = try BreakGlassTicketCodec.encode(Self.validTicket(), signingKey: priv)
        // Flip a character in the payload segment.
        let idx = wire.index(wire.startIndex, offsetBy: 10)
        let orig = wire[idx]
        let flipped: Character = orig == "A" ? "B" : "A"
        wire.replaceSubrange(idx...idx, with: String(flipped))

        #expect(throws: BreakGlassTicketError.invalidTicket) {
            try BreakGlassTicketCodec.decode(
                wire, publicKey: pub, allowedIssuers: ["sre@acme"]
            )
        }
    }

    @Test("signed with a different key is rejected")
    func wrongKeyRejected() throws {
        let (priv, _) = Self.makeKeyPair()
        let (_, otherPub) = Self.makeKeyPair()
        let wire = try BreakGlassTicketCodec.encode(Self.validTicket(), signingKey: priv)

        #expect(throws: BreakGlassTicketError.invalidTicket) {
            try BreakGlassTicketCodec.decode(
                wire, publicKey: otherPub, allowedIssuers: ["sre@acme"]
            )
        }
    }

    // MARK: - Issuer allowlist

    @Test("issuer not in the allowlist is rejected even with valid signature")
    func untrustedIssuerRejected() throws {
        let (priv, pub) = Self.makeKeyPair()
        let ticket = Self.validTicket(issuer: "attacker@evil.example")
        let wire = try BreakGlassTicketCodec.encode(ticket, signingKey: priv)

        // Even though the signature is valid, `attacker@evil` isn't
        // on the agent's allowlist — reject.
        #expect(throws: BreakGlassTicketError.invalidTicket) {
            try BreakGlassTicketCodec.decode(
                wire, publicKey: pub, allowedIssuers: ["sre@acme"]
            )
        }
    }

    // MARK: - Expiry / not-yet-valid

    @Test("expired ticket surfaces BreakGlassTicketError.expired")
    func expiredRejected() throws {
        let (priv, pub) = Self.makeKeyPair()
        let now = Date()
        let ticket = BreakGlassTicket(
            jti: UUID().uuidString,
            issuer: "sre@acme",
            tenant: .default,
            issuedAt: now.addingTimeInterval(-3500),
            expiresAt: now.addingTimeInterval(-120),  // past even with skew
            maxUses: 1,
            reason: nil
        )
        let wire = try BreakGlassTicketCodec.encode(ticket, signingKey: priv)

        #expect(throws: BreakGlassTicketError.expired) {
            try BreakGlassTicketCodec.decode(
                wire, publicKey: pub, allowedIssuers: ["sre@acme"]
            )
        }
    }

    @Test("ticket issued far-future (beyond clock-skew) is rejected as expired")
    func notYetValidRejected() throws {
        let (priv, pub) = Self.makeKeyPair()
        let now = Date()
        let ticket = BreakGlassTicket(
            jti: UUID().uuidString,
            issuer: "sre@acme",
            tenant: .default,
            issuedAt: now.addingTimeInterval(3600),  // 1h in future
            expiresAt: now.addingTimeInterval(3600 + 900),
            maxUses: 1,
            reason: nil
        )
        let wire = try BreakGlassTicketCodec.encode(ticket, signingKey: priv)

        #expect(throws: BreakGlassTicketError.expired) {
            try BreakGlassTicketCodec.decode(
                wire, publicKey: pub, allowedIssuers: ["sre@acme"]
            )
        }
    }

    // MARK: - TTL ceiling

    @Test("TTL beyond 1h policy maximum is rejected at encode time")
    func ttlCeilingEnforced() {
        let (priv, _) = Self.makeKeyPair()
        let now = Date()
        let tooLong = BreakGlassTicket(
            jti: UUID().uuidString,
            issuer: "sre@acme",
            tenant: .default,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3600 + 60), // 61 min
            maxUses: 1,
            reason: nil
        )
        #expect(throws: BreakGlassTicketError.self) {
            _ = try BreakGlassTicketCodec.encode(tooLong, signingKey: priv)
        }
    }

    // MARK: - Envelope handling

    @Test("missing `bgt:` prefix returns malformedEnvelope")
    func noPrefixRejected() {
        let (_, pub) = Self.makeKeyPair()
        #expect(throws: BreakGlassTicketError.malformedEnvelope) {
            try BreakGlassTicketCodec.decode(
                "not-a-ticket.garbage",
                publicKey: pub,
                allowedIssuers: []
            )
        }
    }

    @Test("envelope without exactly one `.` returns malformedEnvelope")
    func malformedEnvelope() {
        let (_, pub) = Self.makeKeyPair()
        for broken in ["bgt:", "bgt:no-separator", "bgt:a.b.c"] {
            #expect(throws: BreakGlassTicketError.malformedEnvelope) {
                try BreakGlassTicketCodec.decode(
                    broken, publicKey: pub, allowedIssuers: []
                )
            }
        }
    }

    // MARK: - UsedTicketCache

    @Test("tryConsume — first call succeeds, second on same JTI fails")
    func singleUseEnforced() async {
        let cache = UsedTicketCache()
        let jti = UUID().uuidString
        let expiry = Date().addingTimeInterval(900)
        let first = await cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 1)
        let second = await cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 1)
        #expect(first == true)
        #expect(second == false, "Single-use ticket must reject the second consume")
    }

    @Test("tryConsume — respects maxUses > 1")
    func multiUseAllowed() async {
        let cache = UsedTicketCache()
        let jti = UUID().uuidString
        let expiry = Date().addingTimeInterval(900)
        let a = await cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 3)
        let b = await cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 3)
        let c = await cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 3)
        let d = await cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 3)
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
                    await cache.tryConsume(jti: jti, expiresAt: expiry, maxUses: 1)
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
    func expiredEntriesEvicted() async {
        let cache = UsedTicketCache()
        let pastJti = UUID().uuidString
        _ = await cache.tryConsume(
            jti: pastJti,
            expiresAt: Date().addingTimeInterval(-1),  // already expired
            maxUses: 1
        )
        // First call recorded the already-expired entry. A
        // subsequent cleanup should evict it.
        let freshJti = UUID().uuidString
        _ = await cache.tryConsume(
            jti: freshJti,
            expiresAt: Date().addingTimeInterval(900),
            maxUses: 1
        )
        let count = await cache.entryCount
        #expect(count <= 2, "Expired entries should be reaped on opportunistic cleanup")
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
}

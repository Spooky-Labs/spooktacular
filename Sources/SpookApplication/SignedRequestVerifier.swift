import Foundation
import CryptoKit
import SpookCore

/// Verifies HTTP requests signed by a trusted client's P-256
/// key. Used by both the guest agent (host-to-agent auth) and
/// the HTTP API server (operator-to-control-plane auth).
///
/// ## Why per-request signing
///
/// A long-lived Bearer token is fundamentally a shared secret:
/// anyone who reads it from disk, process memory, a leaked log
/// line, or a backup can replay it indefinitely. Signed
/// requests replace that with an asymmetric primitive — each
/// caller holds a private key (typically in the Secure Enclave,
/// non-exportable), each server holds an allowlist of caller
/// public keys (not secrets). Compromise of a server or a VM
/// image never yields a usable credential.
///
/// ## Wire format
///
/// Three headers accompany every signed request:
///
/// ```
/// X-Spook-Timestamp: 2026-04-17T18:30:00Z      (ISO-8601, seconds)
/// X-Spook-Nonce:     <uuid>                    (128-bit random)
/// X-Spook-Signature: <base64(64-byte r‖s)>     (P-256 ECDSA raw)
/// ```
///
/// The canonical string signed over is:
///
/// ```
/// <METHOD>\n<path>\n<hex-sha256(body)>\n<timestamp>\n<nonce>
/// ```
///
/// Including the body hash closes chosen-body substitution —
/// an attacker cannot swap the body of a captured signature.
/// Including the nonce closes replay within the skew window.
///
/// ## Replay protection
///
/// Nonces are cached for `nonceTTL` seconds. A second request
/// with the same nonce is rejected regardless of signature
/// validity. Combined with the timestamp-skew window
/// (`clockSkew`), an attacker who captures a signed request
/// has at most one shot within the skew window, and zero
/// shots after.
public final class SignedRequestVerifier: @unchecked Sendable {

    /// Outcome of a verification attempt.
    public enum VerifyError: Error, Equatable {
        /// One or more required headers were absent.
        case missingHeaders
        /// The timestamp is outside the ±`clockSkew` window.
        case timestampOutOfRange
        /// The nonce has already been seen in the replay cache.
        case replay
        /// The signature is malformed or did not verify against
        /// any trusted key.
        case invalidSignature
    }

    private let trustedKeys: [P256.Signing.PublicKey]
    private let clockSkew: TimeInterval
    private let nonceTTL: TimeInterval
    private let nonceCache: NonceCache
    private let fleetSingleton: (any FleetSingleton)?
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - trustedKeys: Operator-provisioned allowlist of caller
    ///     public keys. Verification succeeds if any one of
    ///     these accepts the signature.
    ///   - clockSkew: Maximum absolute difference between the
    ///     claimed timestamp and the verifier's clock, in
    ///     seconds. Defaults to 60s.
    ///   - nonceTTL: How long a nonce is remembered after first
    ///     use, in seconds. Must be ≥ 2 × clockSkew so a replay
    ///     cannot simply wait for the cache entry to expire.
    ///     Defaults to 300s (5 minutes).
    ///   - fleetSingleton: Fleet-wide replay cache. When
    ///     provided, the per-process `NonceCache` is used as a
    ///     first-tier fast-path; the singleton is the source of
    ///     truth across hosts. Must be set in multi-controller
    ///     deployments; `nil` is valid only for single-host
    ///     installations.
    ///   - clock: Injectable clock for tests.
    public init(
        trustedKeys: [P256.Signing.PublicKey],
        clockSkew: TimeInterval = 60,
        nonceTTL: TimeInterval = 300,
        fleetSingleton: (any FleetSingleton)? = nil,
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.trustedKeys = trustedKeys
        self.clockSkew = clockSkew
        self.nonceTTL = nonceTTL
        self.nonceCache = NonceCache()
        self.fleetSingleton = fleetSingleton
        self.clock = clock
    }

    /// True iff any trusted keys were provided.
    public var hasTrustedKeys: Bool { !trustedKeys.isEmpty }

    /// True when a fleet-wide singleton is wired and this
    /// verifier will reject replays observed on peer hosts.
    public var hasFleetReplayProtection: Bool { fleetSingleton != nil }

    /// Fleet-wide verify: identical to ``verify(method:path:headers:body:)``
    /// but first consults the configured ``FleetSingleton`` (if
    /// any) to reject replays across controllers. A fleet-level
    /// hit short-circuits before the per-process claim + signature
    /// check — once a peer host has consumed the nonce, no other
    /// host may accept it either.
    public func verifyFleetWide(
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) async throws -> P256.Signing.PublicKey {
        guard let fleet = fleetSingleton else {
            // Degrade to per-process verification explicitly —
            // the caller opted out of fleet-wide replay by not
            // wiring a singleton. The preflight check refuses
            // this combination in multi-tenant mode.
            return try verify(method: method, path: path, headers: headers, body: body)
        }
        guard
            let nonce = headers["x-spook-nonce"]?.trimmingCharacters(in: .whitespaces),
            !nonce.isEmpty
        else {
            throw VerifyError.missingHeaders
        }
        let outcome = try await fleet.mark(id: "nonce:\(nonce)", ttl: nonceTTL)
        switch outcome {
        case .alreadyConsumed:
            throw VerifyError.replay
        case .freshMark:
            // Fleet-wide claim granted. Now run the local path;
            // on a local signature failure, we deliberately do
            // NOT unmark the fleet entry — a legitimate retry is
            // impossible with the same nonce anyway, because
            // every client is required to generate a fresh UUID
            // per request. Leaving the mark in place is strictly
            // safer (closes a release-after-sig-fail replay
            // window that the local-only path has to reopen).
            return try verify(
                method: method, path: path, headers: headers, body: body
            )
        }
    }

    /// Verifies a signed request. On success, returns the
    /// public key that accepted the signature — useful for
    /// audit attribution. On failure, throws a ``VerifyError``.
    public func verify(
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) throws -> P256.Signing.PublicKey {
        guard !trustedKeys.isEmpty else {
            throw VerifyError.invalidSignature
        }
        guard
            let timestamp = headers["x-spook-timestamp"]?.trimmingCharacters(in: .whitespaces),
            let nonce = headers["x-spook-nonce"]?.trimmingCharacters(in: .whitespaces),
            let signatureB64 = headers["x-spook-signature"]?.trimmingCharacters(in: .whitespaces),
            !timestamp.isEmpty, !nonce.isEmpty, !signatureB64.isEmpty
        else {
            throw VerifyError.missingHeaders
        }

        guard let ts = Self.parseISO8601(timestamp) else {
            throw VerifyError.timestampOutOfRange
        }
        let now = clock()
        guard abs(now.timeIntervalSince(ts)) <= clockSkew else {
            throw VerifyError.timestampOutOfRange
        }

        // Claim the nonce **before** verifying the signature. A
        // valid-signature, valid-timestamp replay would otherwise
        // be rejected on the second attempt only — but an
        // attacker doesn't care about the second attempt if the
        // first one executed. Order: claim → verify → consume.
        // If verification fails, we release the nonce so a
        // legitimate retry isn't blocked.
        guard nonceCache.claim(nonce: nonce, expiry: now.addingTimeInterval(nonceTTL)) else {
            throw VerifyError.replay
        }

        guard let signatureBytes = Data(base64Encoded: signatureB64),
              signatureBytes.count == 64 else {
            nonceCache.release(nonce: nonce)
            throw VerifyError.invalidSignature
        }
        let ecdsa: P256.Signing.ECDSASignature
        do {
            ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        } catch {
            nonceCache.release(nonce: nonce)
            throw VerifyError.invalidSignature
        }

        let bodyHashHex = Self.hexSHA256(body)
        let canonical = "\(method.uppercased())\n\(path)\n\(bodyHashHex)\n\(timestamp)\n\(nonce)"
        let canonicalData = Data(canonical.utf8)

        for key in trustedKeys {
            if key.isValidSignature(ecdsa, for: canonicalData) {
                return key
            }
        }

        // Signature didn't verify. Release the nonce so the same
        // client can legitimately retry with a fresh signature
        // (e.g., after a transient transport glitch re-used the
        // same nonce). Security-wise this is safe: no trusted
        // key accepted the signature, so there's nothing to
        // replay.
        nonceCache.release(nonce: nonce)
        throw VerifyError.invalidSignature
    }

    // MARK: - Helpers

    /// ISO-8601 parser that accepts the seconds-precision form
    /// our signers emit. Uses a stable formatter so parsing is
    /// deterministic across locale changes.
    public static func parseISO8601(_ s: String) -> Date? {
        if let d = _iso8601Strict.date(from: s) { return d }
        return _iso8601Fractional.date(from: s)
    }

    nonisolated(unsafe) private static let _iso8601Strict: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let _iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// SHA-256 hex digest, lowercase.
    public static func hexSHA256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Nonce cache

/// Thread-safe dictionary of nonce → expiry-instant. Replay-
/// protects the verifier against two-shot attacks within the
/// clock-skew window.
private final class NonceCache: @unchecked Sendable {
    private var entries: [String: Date] = [:]
    private let lock = NSLock()

    /// Reserves `nonce` until `expiry`. Returns `true` on first
    /// claim; `false` if the nonce is already in the cache
    /// (replay).
    func claim(nonce: String, expiry: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        prune(now: Date())
        if entries[nonce] != nil { return false }
        entries[nonce] = expiry
        return true
    }

    /// Releases a previously-claimed nonce so a legitimate
    /// retry isn't blocked when the signature itself failed.
    func release(nonce: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: nonce)
    }

    private func prune(now: Date) {
        entries = entries.filter { $0.value > now }
    }
}

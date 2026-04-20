import Foundation
import Security
import os

/// Keychain-persisted ``SigV4RequestSigner/CredentialProvider``.
///
/// ## Why persist at all
///
/// The Secure Enclave cannot hold raw HMAC keys (it only does
/// P-256 ECDSA/ECDH). STS session credentials are HMAC keys,
/// so they can't get SEP-level protection. The next-best
/// Apple-native resting place is the Keychain with strict
/// access-control flags:
///
/// - **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`** — the
///   item is decryptable only when the device is unlocked,
///   and it never syncs to iCloud Keychain. If the disk is
///   stolen while the machine is locked, the creds can't be
///   read.
/// - **`kSecAttrSynchronizable = false`** — belt-and-braces:
///   never leaves this Mac.
/// - **`SecAccessControlCreateFlags.privateKeyUsage` +
///   `.biometryCurrentSet`** (optional via
///   ``requiresBiometry``) — Touch ID / Watch prompt on
///   every read. The `currentSet` variant invalidates the
///   stored creds on any change to enrolled biometrics, so
///   adding / removing a fingerprint requires re-federating
///   through STS.
///
/// The actor rotates the cached value in memory too, so
/// consecutive signs within a single process don't hit the
/// Keychain more than once — the Keychain is just the
/// cold-start / post-crash fallback.
///
/// ## Threat model improvement over in-memory-only
///
/// Without Keychain: every CLI invocation re-calls STS (~300 ms
/// round-trip, plus a second on the guest-agent side to sign
/// the OIDC token in the SEP). This also puts load on IAM
/// federation.
/// With Keychain: first `aws ebs attach` federates and
/// caches; subsequent invocations within the 1-hour STS
/// window read from Keychain. Re-federation happens
/// automatically when the cached item's `expiresAt` < now + 60 s.
///
/// ## Apple APIs
///
/// - [`SecItemAdd`](https://developer.apple.com/documentation/security/1401659-secitemadd)
///   / [`SecItemUpdate`](https://developer.apple.com/documentation/security/1393617-secitemupdate)
///   / [`SecItemCopyMatching`](https://developer.apple.com/documentation/security/1398306-secitemcopymatching)
///   / [`SecItemDelete`](https://developer.apple.com/documentation/security/1395547-secitemdelete)
/// - [`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly)
/// - [`SecAccessControlCreateWithFlags`](https://developer.apple.com/documentation/security/1394363-secaccesscontrolcreatewithflags)
///   for the biometry gate.
public actor KeychainCredentialProvider: SigV4RequestSigner.CredentialProvider {

    /// Shape of the payload we store in the Keychain's
    /// password slot. Codable so the Keychain round-trip is
    /// a single JSON encode / decode.
    private struct StoredCredentials: Codable, Sendable {
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String?
        let expiresAt: Date

        var asSigV4Credentials: SigV4Signer.Credentials {
            SigV4Signer.Credentials(
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                sessionToken: sessionToken
            )
        }
    }

    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "credential-provider"
    )

    /// Keychain service label. One per AWS role ARN + region
    /// pair, so distinct roles don't collide.
    public let service: String

    /// Keychain account label — the caller's logical
    /// identifier, typically `"<tenant>@<role-arn>"`.
    public let account: String

    /// When true, the Keychain access-control flags require a
    /// Touch ID / Apple Watch prompt on every read. Defaults
    /// to `false` — matches the expectation for headless CI
    /// hosts that need unattended access.
    public let requiresBiometry: Bool

    /// Underlying refresher that fetches fresh credentials
    /// when the Keychain is empty or the cached item is close
    /// to expiry. Typically wraps
    /// `AssumeRoleWithWebIdentity` signed by an SEP-held
    /// OIDC private key from `P256KeyStore`.
    private let refresher: any SigV4RequestSigner.CredentialProvider

    /// In-process cache so repeated signs within the same
    /// process skip the Keychain round-trip.
    private var memoryCache: StoredCredentials?

    /// Refresh grace — same 60 s window
    /// ``SigV4RequestSigner`` uses.
    private let refreshGrace: TimeInterval = 60

    public init(
        service: String,
        account: String,
        requiresBiometry: Bool = false,
        refresher: any SigV4RequestSigner.CredentialProvider
    ) {
        self.service = service
        self.account = account
        self.requiresBiometry = requiresBiometry
        self.refresher = refresher
    }

    public func credentials() async throws -> SigV4Signer.Credentials {
        // Tier 1: in-memory cache.
        if let cached = memoryCache,
           cached.expiresAt.timeIntervalSinceNow > refreshGrace {
            return cached.asSigV4Credentials
        }

        // Tier 2: Keychain.
        if let fromKeychain = readFromKeychain(),
           fromKeychain.expiresAt.timeIntervalSinceNow > refreshGrace {
            memoryCache = fromKeychain
            return fromKeychain.asSigV4Credentials
        }

        // Tier 3: refresh via STS / WorkloadTokenIssuer.
        let fresh = try await refresher.credentials()
        let stored = StoredCredentials(
            accessKeyID: fresh.accessKeyID,
            secretAccessKey: fresh.secretAccessKey,
            sessionToken: fresh.sessionToken,
            // STS `AssumeRoleWithWebIdentity` default is
            // 3600 s. The refresher should carry its own
            // expiry in a follow-up refactor; until then we
            // apply a conservative 55 min here.
            expiresAt: Date().addingTimeInterval(55 * 60)
        )
        memoryCache = stored
        writeToKeychain(stored)
        return fresh
    }

    /// Deletes the Keychain entry. Call on logout / tenant
    /// switch so the next user doesn't inherit creds.
    public func invalidate() {
        memoryCache = nil
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
        _ = SecItemDelete(query as CFDictionary)
        _ = query // silence unused-var in release builds
    }

    // MARK: - Keychain IO

    private func readFromKeychain() -> StoredCredentials? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Self.log.warning(
                    "Keychain read failed: status=\(status, privacy: .public)"
                )
            }
            return nil
        }
        do {
            return try JSONDecoder().decode(StoredCredentials.self, from: data)
        } catch {
            Self.log.warning(
                "Keychain payload decode failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func writeToKeychain(_ creds: StoredCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }

        var attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecValueData: data,
        ]

        if requiresBiometry {
            // Biometric gate via `SecAccessControl`. The
            // `.biometryCurrentSet` flag invalidates the
            // stored creds on any change to enrolled
            // biometrics — matches the ASVS requirement that
            // revoking a biometric factor invalidate
            // credentials gated by it.
            var acError: Unmanaged<CFError>?
            guard let ac = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.biometryCurrentSet],
                &acError
            ) else {
                Self.log.warning("SecAccessControl create failed; skipping Keychain write")
                return
            }
            attrs[kSecAttrAccessControl] = ac
        } else {
            attrs[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        // Write-or-update: delete the existing item first so
        // the biometry / accessibility flags take effect on
        // every rotation (SecItemUpdate preserves the
        // original ACL).
        var deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)
        _ = deleteQuery

        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Self.log.warning(
                "Keychain write failed: status=\(addStatus, privacy: .public)"
            )
        }
    }
}

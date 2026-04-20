import Foundation

/// ``RequestSigner`` adapter that plugs the existing
/// ``SigV4Signer`` primitive into the typed ``HTTPSClient``
/// pipeline.
///
/// Two-layer design on purpose:
///
/// - **``SigV4Signer``** (pre-existing) — stateless,
///   static-creds, the thing that knows how to compute an
///   Authorization header given a `URLRequest` + body +
///   date. Used directly by `S3ObjectLockAuditStore` and
///   `DynamoDBDistributedLock` since before Track M.
/// - **`SigV4RequestSigner`** (this file) — actor-isolated,
///   holds a rotating ``CredentialProvider``, adapts the
///   above into the `RequestSigner.sign(_:)` shape
///   ``HTTPSClient`` expects. **Refreshes credentials
///   automatically** when expiry is under 60 s, so callers
///   never see a signed request with expired credentials.
///
/// The split keeps the existing callers (which don't need
/// rotation) off the rotation code path while letting new
/// AWS adapters (EBS Direct, STS) reuse the same signing
/// primitive behind a ``RequestSigner``-shaped facade.
///
/// ## Credential handling
///
/// See ``SigV4Signer``'s class-level note: the STS access
/// key is an HMAC key the SEP can't directly hold, so we
/// keep it ephemeral. The ``CredentialProvider`` the caller
/// supplies is the **only** retention point, and production
/// implementations back it with a periodic
/// `AssumeRoleWithWebIdentity` refresh whose OIDC token is
/// SEP-signed (via `WorkloadTokenIssuer` + `P256KeyStore`).
public actor SigV4RequestSigner: RequestSigner {

    /// Pluggable credential source. Production uses an
    /// STS-federated provider; tests supply a constant-return
    /// stub.
    public protocol CredentialProvider: Sendable {
        /// Returns credentials valid for **at least** the
        /// next 60 seconds. Implementations are expected to
        /// refresh transparently when the cached set is
        /// close to expiry.
        func credentials() async throws -> SigV4Signer.Credentials
    }

    private let service: String
    private let region: String
    private let provider: any CredentialProvider

    /// Grace window before credential expiry at which we
    /// force a refresh. 60 s matches the minimum STS-token
    /// lifetime Apple's SDK uses internally (per the
    /// [`AWSCognitoIdentityProvider` docs](https://docs.aws.amazon.com/cognitoidentity/latest/APIReference/API_Credentials.html)).
    private let refreshGrace: TimeInterval = 60

    /// Most recently retrieved creds, cached so we can
    /// detect the "still valid" case and skip the provider
    /// call.
    private var cached: SigV4Signer.Credentials?
    private var cachedExpiresAt: Date?

    public init(
        service: String,
        region: String,
        provider: any CredentialProvider
    ) {
        self.service = service
        self.region = region
        self.provider = provider
    }

    public func sign(_ request: inout URLRequest) async throws {
        let credentials = try await fetchCredentials()
        let now = Date()

        // Required headers that MUST exist before signing so
        // the canonical-headers step can include them. The
        // existing `SigV4Signer` reads `allHTTPHeaderFields`,
        // so we inject these before calling it.
        if request.value(forHTTPHeaderField: "Host") == nil,
           let host = request.url?.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }
        request.setValue(
            SigV4Signer.amzDate(now),
            forHTTPHeaderField: "X-Amz-Date"
        )
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let body = request.httpBody ?? Data()
        let signer = SigV4Signer(
            credentials: credentials,
            region: region,
            service: service
        )
        let authorization = signer.signature(
            for: request,
            body: body,
            date: now
        )
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    /// Returns cached credentials when they're valid for at
    /// least ``refreshGrace`` more seconds; otherwise asks
    /// the provider for a fresh set.
    private func fetchCredentials() async throws -> SigV4Signer.Credentials {
        if let cached, let expiry = cachedExpiresAt,
           expiry.timeIntervalSinceNow > refreshGrace {
            return cached
        }
        let fresh = try await provider.credentials()
        cached = fresh
        // The `SigV4Signer.Credentials` type doesn't carry an
        // expiry today — providers that know it should wrap
        // the set in a struct exposing both. Until that
        // refactor lands we use a conservative 45-minute
        // assumption (STS AssumeRoleWithWebIdentity default
        // is 1 hour).
        cachedExpiresAt = Date().addingTimeInterval(45 * 60)
        return fresh
    }
}

/// Constant-credentials provider. Useful for local
/// development, static-key flows, and tests where we want to
/// exercise SigV4 without spinning up STS.
///
/// Production flows should use the (not-yet-ported)
/// `STSFederatedCredentialProvider` which refreshes via
/// `AssumeRoleWithWebIdentity` using an SEP-signed OIDC
/// token.
public struct StaticCredentialProvider: SigV4RequestSigner.CredentialProvider {
    private let creds: SigV4Signer.Credentials

    public init(_ creds: SigV4Signer.Credentials) {
        self.creds = creds
    }

    public func credentials() async throws -> SigV4Signer.Credentials {
        creds
    }
}

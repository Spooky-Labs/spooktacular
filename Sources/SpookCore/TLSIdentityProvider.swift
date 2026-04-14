import Foundation

/// Provides TLS identity and trust evaluation for mutual TLS.
///
/// The Infrastructure layer provides a ``KeychainTLSProvider``
/// implementation that loads client certificates from the Keychain.
/// Tests can inject a mock that returns a plain ephemeral session.
///
/// ## Clean Architecture
///
/// Controllers define WHAT security posture they need for node
/// communication. The ``TLSIdentityProvider`` protocol is the port;
/// ``KeychainTLSProvider`` is the adapter. ``NodeManager`` depends on
/// this protocol, not on `Security` or `SecIdentity` directly.
public protocol TLSIdentityProvider: Sendable {
    /// Returns a `URLSession` configured with client certificate
    /// authentication and a custom trust policy for mutual TLS.
    ///
    /// The returned session pins trust to the CA that signed the
    /// server certificate and presents the client identity on
    /// `NSURLAuthenticationMethodClientCertificate` challenges.
    func configuredSession() -> URLSession
}

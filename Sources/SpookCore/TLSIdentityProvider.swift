import Foundation

/// Produces a pre-configured ``HTTPClient`` for mutual-TLS calls.
///
/// The Infrastructure layer provides a ``KeychainTLSProvider``
/// implementation that loads client certificates from the Keychain
/// and returns an `HTTPClient` whose transport performs mTLS with
/// anchor-pinned server trust. Tests inject a mock that returns any
/// `HTTPClient` — a plain ephemeral session, a stub, whatever the
/// test needs.
///
/// ## Clean Architecture
///
/// Controllers declare WHAT security posture they need for node
/// communication. The ``TLSIdentityProvider`` protocol is the port;
/// ``KeychainTLSProvider`` is the adapter. ``NodeManager`` depends on
/// this protocol, not on `URLSession`, `Security`, or `SecIdentity`
/// directly — keeping the domain layer free of infrastructure types.
public protocol TLSIdentityProvider: Sendable {

    /// Returns an ``HTTPClient`` pre-configured with client-certificate
    /// authentication and anchor-pinned server trust.
    ///
    /// Callers invoke the returned client with ``DomainHTTPRequest``
    /// values; the client executes them over mutual TLS.
    func makeHTTPClient() -> any HTTPClient
}

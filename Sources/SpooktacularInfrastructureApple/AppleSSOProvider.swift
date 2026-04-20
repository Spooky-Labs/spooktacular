import Foundation
import AuthenticationServices
import SpooktacularCore
import SpooktacularApplication

/// Identity verification using Apple's ASAuthorization framework.
///
/// Uses `ASAuthorizationSingleSignOnProvider` for enterprise SSO
/// when the host is MDM-managed and has an SSO extension configured.
///
/// ## When to use
///
/// - macOS hosts enrolled in MDM with an SSO extension (Okta, Azure AD,
///   PingFederate via their macOS extensions)
/// - Interactive authentication flows (GUI app, not headless daemon)
///
/// ## When NOT to use
///
/// - Headless server-side token verification (`spook serve`) — use
///   `OIDCTokenVerifier` instead, which validates JWTs server-side
///   without requiring a browser or MDM
/// - CI environments without a logged-in user session
///
/// ## Apple API Reference
///
/// - [ASAuthorizationSingleSignOnProvider](https://developer.apple.com/documentation/authenticationservices/asauthorizationsinglesignonprovider)
/// - [Enterprise SSO](https://developer.apple.com/documentation/authenticationservices/enterprise-single-sign-on-sso)
///
/// Note: This requires the `com.apple.developer.extensible-app-sso`
/// entitlement and an MDM-configured SSO extension.
public final class AppleSSOProvider: NSObject, Sendable {
    private let identityProviderURL: URL

    public init(identityProviderURL: URL) {
        self.identityProviderURL = identityProviderURL
    }

    /// Checks whether an SSO extension is available for this provider.
    public var isAvailable: Bool {
        let provider = ASAuthorizationSingleSignOnProvider(
            identityProvider: identityProviderURL
        )
        return provider.canPerformAuthorization
    }
}

import Testing
import Foundation
@testable import SpooktacularKit

/// Parity with `GitHubTokenResolutionTests` — verifies the
/// webhook-HMAC-secret resolver returns `keychainMiss` with the
/// account name, exposes an actionable recovery hint, and has
/// a description for every error case.
///
/// The resolver is Keychain-only by design: env-var and file
/// paths were excluded to close the "malware running as the
/// logged-in user" threat. These tests hit the real system
/// Keychain with a throwaway UUID account, so they're safe to
/// run in CI without disturbing operator secrets.
@Suite("Webhook secret resolution", .tags(.security))
struct WebhookSecretResolutionTests {

    @Test("absent Keychain item throws .keychainMiss carrying the account")
    func keychainMissCarriesAccount() {
        let absent = "spooktacular-test-\(UUID().uuidString)"
        #expect {
            try WebhookSecretResolver.resolve(keychainAccount: absent)
        } throws: { error in
            if case WebhookSecretError.keychainMiss(let a) = error,
               a == absent {
                return true
            }
            return false
        }
    }

    @Test("recoverySuggestion names the exact `security` incantation")
    func recoveryHintIsActionable() {
        let err = WebhookSecretError.keychainMiss(account: "github-webhook-org-acme")
        let hint = err.recoverySuggestion ?? ""
        #expect(hint.contains("security add-generic-password"))
        #expect(hint.contains("com.spooktacular.webhook"))
        #expect(hint.contains("github-webhook-org-acme"))
    }

    @Test("every error case has both description and recovery hint")
    func everyCaseIsSelfDescribing() {
        let cases: [WebhookSecretError] = [
            .keychainMiss(account: "acme"),
        ]
        for err in cases {
            #expect(err.errorDescription?.isEmpty == false)
            #expect(err.recoverySuggestion?.isEmpty == false)
        }
    }
}

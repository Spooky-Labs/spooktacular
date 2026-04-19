import Testing
import Foundation
@testable import SpooktacularKit

/// Covers the Keychain-only resolution path for the GitHub runner
/// registration token. Earlier revisions accepted env-var, CLI
/// flag, and file-path sources; those were removed to close the
/// "malware running as the logged-in user" threat (see
/// `docs/THREAT_MODEL.md` for rationale).
///
/// The Keychain-miss path is exercised against the real system
/// Keychain using a throwaway UUID account name — no actual
/// tokens are written, so the tests are safe to run in CI.
@Suite("GitHub token resolution", .tags(.security))
struct GitHubTokenResolutionTests {

    @Test("absent Keychain item throws .keychainMiss carrying the account")
    func keychainMissCarriesAccount() {
        // A UUID account name guarantees the Keychain has no
        // matching item — we can exercise the miss path without
        // touching the user's real secret store.
        let absent = "spooktacular-test-\(UUID().uuidString)"
        #expect {
            try GitHubTokenResolver.resolve(keychainAccount: absent)
        } throws: { error in
            if case GitHubTokenError.keychainMiss(let a) = error,
               a == absent {
                return true
            }
            return false
        }
    }

    @Test("recoverySuggestion names the exact `security` incantation")
    func recoveryHintIsActionable() {
        // The CLI renders this verbatim — if it ever drops the
        // `security add-generic-password -s com.spooktacular.github`
        // prefix the operator has to translate the hint back into a
        // command, which defeats the "one-shot fix" goal.
        let err = GitHubTokenError.keychainMiss(account: "org-acme")
        let hint = err.recoverySuggestion ?? ""
        #expect(hint.contains("security add-generic-password"))
        #expect(hint.contains("com.spooktacular.github"))
        #expect(hint.contains("org-acme"))
    }

    @Test("every error case has both description and recovery hint")
    func everyCaseIsSelfDescribing() {
        let cases: [GitHubTokenError] = [
            .keychainMiss(account: "acme"),
        ]
        for err in cases {
            #expect(err.errorDescription?.isEmpty == false)
            #expect(err.recoverySuggestion?.isEmpty == false)
        }
    }
}

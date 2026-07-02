import Testing
import Foundation
@testable import SpooktacularKit

/// Covers the Keychain-only resolution path for the GitHub PAT
/// (from which the host mints short-lived runner registration
/// tokens). Earlier revisions accepted env-var, CLI
/// flag, and file-path sources; those were removed to close the
/// "malware running as the logged-in user" threat — a sibling
/// process reading an env var, CLI arg, or world-readable file
/// can't reach a Keychain item without also passing the OS's own
/// ACL check.
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
        // The Keychain item is a PAT (the host mints short-lived
        // registration tokens from it at create time) — the hint
        // must say so, or operators paste a 1-hour registration
        // token that dies before a 40-minute install finishes.
        #expect(hint.contains("<PAT with repo admin scope>"))
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

import Testing
import Foundation
@testable import SpooktacularKit

/// Covers the four-source resolution chain for the GitHub runner
/// registration token. Priority: file > Keychain > env > flag.
///
/// The Keychain-miss path is exercised against the real system
/// Keychain using a throwaway account name — no actual tokens are
/// written, so the test is safe to run in CI.
@Suite("GitHub token resolution", .tags(.security))
struct GitHubTokenResolutionTests {

    @Test("missing everywhere → .missing")
    func missingEverywhere() {
        unsetenv("SPOOK_GITHUB_TOKEN")
        #expect {
            try GitHubTokenResolver.resolve(
                flagValue: nil, filePath: nil, keychainAccount: nil
            )
        } throws: { error in
            if case GitHubTokenError.missing = error { return true }
            return false
        }
    }

    @Test("flag value is last-resort fallback")
    func flagOnlyReturnsFlag() throws {
        unsetenv("SPOOK_GITHUB_TOKEN")
        let token = try GitHubTokenResolver.resolve(
            flagValue: "ghp_flag_value",
            filePath: nil,
            keychainAccount: nil
        )
        #expect(token == "ghp_flag_value")
    }

    @Test("SPOOK_GITHUB_TOKEN env wins over the flag")
    func envBeatsFlag() throws {
        setenv("SPOOK_GITHUB_TOKEN", "ghp_from_env", 1)
        defer { unsetenv("SPOOK_GITHUB_TOKEN") }
        let token = try GitHubTokenResolver.resolve(
            flagValue: "ghp_flag_value",
            filePath: nil,
            keychainAccount: nil
        )
        #expect(token == "ghp_from_env")
    }

    @Test("file wins over env and flag")
    func fileBeatsEnvAndFlag() throws {
        setenv("SPOOK_GITHUB_TOKEN", "ghp_from_env", 1)
        defer { unsetenv("SPOOK_GITHUB_TOKEN") }
        let tmp = NSTemporaryDirectory() + "gh-\(UUID().uuidString).token"
        try "ghp_from_file\n".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let token = try GitHubTokenResolver.resolve(
            flagValue: "ghp_flag_value",
            filePath: tmp,
            keychainAccount: nil
        )
        #expect(token == "ghp_from_file", "File source wins and trailing whitespace is stripped")
    }

    @Test("empty file is rejected with a specific error")
    func emptyFileIsRejected() throws {
        let tmp = NSTemporaryDirectory() + "empty-\(UUID().uuidString).token"
        try "".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect {
            try GitHubTokenResolver.resolve(
                flagValue: nil, filePath: tmp, keychainAccount: nil
            )
        } throws: { error in
            if case GitHubTokenError.emptyFile(let p) = error, p == tmp { return true }
            return false
        }
    }

    @Test("missing file is rejected with an unreadable error carrying the path")
    func missingFileIsRejected() throws {
        let nonexistent = "/tmp/spooktacular-nonexistent-\(UUID().uuidString)"
        #expect {
            try GitHubTokenResolver.resolve(
                flagValue: nil, filePath: nonexistent, keychainAccount: nil
            )
        } throws: { error in
            if case GitHubTokenError.unreadableFile(let p, _) = error, p == nonexistent { return true }
            return false
        }
    }

    @Test("missing Keychain account throws .keychainMiss with the account name")
    func keychainMissCarriesAccount() {
        // A UUID account name guarantees the Keychain has no
        // matching item — we can exercise the miss path without
        // touching the user's real secret store.
        let absent = "spooktacular-test-\(UUID().uuidString)"
        #expect {
            try GitHubTokenResolver.resolve(
                flagValue: nil, filePath: nil, keychainAccount: absent
            )
        } throws: { error in
            if case GitHubTokenError.keychainMiss(let a) = error, a == absent { return true }
            return false
        }
    }

    @Test("error recoverySuggestion is populated for every case")
    func everyCaseHasRecoveryHint() {
        let cases: [GitHubTokenError] = [
            .missing,
            .emptyFile(path: "/tmp/foo"),
            .unreadableFile(path: "/tmp/foo", underlying: POSIXError(.ENOENT)),
            .keychainMiss(account: "acme"),
        ]
        for err in cases {
            #expect(err.errorDescription?.isEmpty == false)
            #expect(err.recoverySuggestion?.isEmpty == false)
        }
    }
}

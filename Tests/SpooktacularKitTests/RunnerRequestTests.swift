import Testing
import Foundation
@testable import SpooktacularApplication

@Suite("RunnerRequest")
struct RunnerRequestTests {

    @Test("valid repo + keychain account constructs with defaults")
    func validMinimal() throws {
        let request = try RunnerRequest(repo: "acme-inc/platform", keychainAccount: "org-acme")
        #expect(request.repo == "acme-inc/platform")
        #expect(request.keychainAccount == "org-acme")
        #expect(request.labels == [])
        #expect(request.ephemeral == false)
    }

    @Test("all fields populated")
    func validFull() throws {
        let request = try RunnerRequest(
            repo: "acme-inc/platform",
            keychainAccount: "org-acme",
            labels: ["gpu", "macos-26"],
            ephemeral: true
        )
        #expect(request.labels == ["gpu", "macos-26"])
        #expect(request.ephemeral == true)
    }

    @Test("trims whitespace from repo and keychain account")
    func trimsWhitespace() throws {
        let request = try RunnerRequest(
            repo: "  acme-inc/platform  ",
            keychainAccount: "  org-acme  "
        )
        #expect(request.repo == "acme-inc/platform")
        #expect(request.keychainAccount == "org-acme")
    }

    @Test("empty repo throws emptyRepo")
    func emptyRepo() {
        #expect(throws: RunnerRequestError.emptyRepo) {
            _ = try RunnerRequest(repo: "", keychainAccount: "org-acme")
        }
    }

    @Test("whitespace-only repo throws emptyRepo")
    func whitespaceOnlyRepo() {
        #expect(throws: RunnerRequestError.emptyRepo) {
            _ = try RunnerRequest(repo: "   ", keychainAccount: "org-acme")
        }
    }

    @Test("empty keychain account throws emptyKeychainAccount")
    func emptyKeychainAccount() {
        #expect(throws: RunnerRequestError.emptyKeychainAccount) {
            _ = try RunnerRequest(repo: "acme-inc/platform", keychainAccount: "")
        }
    }

    @Test("repo without a slash fails GitHubRunnerScope shape validation")
    func malformedRepoNoSlash() {
        #expect(throws: (any Error).self) {
            _ = try RunnerRequest(repo: "acme-inc", keychainAccount: "org-acme")
        }
    }

    @Test("repo with too many path segments fails shape validation")
    func malformedRepoExtraSegments() {
        #expect(throws: (any Error).self) {
            _ = try RunnerRequest(repo: "acme-inc/platform/extra", keychainAccount: "org-acme")
        }
    }

    @Test("empty-repo check runs before the shape check")
    func emptyCheckPrecedesShapeCheck() {
        // A blank repo must surface the friendlier `emptyRepo`
        // message, not GitHubRunnerScope's "invalid scope" text.
        #expect(throws: RunnerRequestError.emptyRepo) {
            _ = try RunnerRequest(repo: "   ", keychainAccount: "org-acme")
        }
    }

    @Test("error descriptions and recovery suggestions are non-nil")
    func errorText() {
        for error: RunnerRequestError in [.emptyRepo, .emptyKeychainAccount] {
            #expect(error.errorDescription != nil)
            #expect(error.recoverySuggestion != nil)
        }
    }
}

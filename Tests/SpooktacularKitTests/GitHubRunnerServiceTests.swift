import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("GitHubRunnerService")
struct GitHubRunnerServiceTests {

    @Test("PAT auth returns token")
    func patAuth() async throws {
        let auth = GitHubPATAuth(token: "ghp_test123")
        let result = try await auth.token()
        #expect(result == "ghp_test123")
    }

    @Test("RegistrationTokenResponse decodes")
    func decodeToken() throws {
        let json = """
        {"token":"LLBMS-FAKE","expires_at":"2020-01-22T12:13:35.123-08:00"}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(RegistrationTokenResponse.self, from: data)
        #expect(decoded.token == "LLBMS-FAKE")
    }

    @Test("Error has description")
    func errorDesc() {
        let invalidResponse = GitHubServiceError.invalidResponse
        #expect(invalidResponse.errorDescription != nil)

        let apiError = GitHubServiceError.apiError(statusCode: 404, body: "Not Found")
        #expect(apiError.errorDescription?.contains("404") == true)
        #expect(apiError.errorDescription?.contains("Not Found") == true)
    }
}

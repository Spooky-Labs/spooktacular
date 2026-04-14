import Testing
import Foundation
@testable import SpooktacularKit

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

    @Test("RunnerListResponse decodes with labels")
    func decodeList() throws {
        let json = """
        {
          "total_count": 1,
          "runners": [
            {
              "id": 42,
              "name": "macos-arm64-01",
              "status": "online",
              "busy": false,
              "labels": [
                {"name": "self-hosted"},
                {"name": "macOS"}
              ]
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(RunnerListResponse.self, from: data)
        #expect(decoded.runners.count == 1)
        let runner = decoded.runners[0]
        #expect(runner.id == 42)
        #expect(runner.name == "macos-arm64-01")
        #expect(runner.status == "online")
        #expect(runner.busy == false)
        #expect(runner.labels.count == 2)
        #expect(runner.labels[0].name == "self-hosted")
        #expect(runner.labels[1].name == "macOS")
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

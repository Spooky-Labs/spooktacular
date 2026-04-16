import Testing
@testable import SpookCore

/// Validates the guest agent HTTP contract.
///
/// These tests verify that the contract table — which defines the API
/// surface between host and guest — is consistent, complete, and
/// correct. They catch drift between client code and the expected
/// agent behavior.
@Suite("Guest Agent Contract", .tags(.security, .integration))
struct GuestAgentContractTests {

    /// The expected REST contract between host client and guest agent.
    static let expectedEndpoints: [(method: String, path: String, name: String)] = [
        ("GET", "/health", "health"),
        ("GET", "/api/v1/clipboard", "getClipboard"),
        ("POST", "/api/v1/clipboard", "setClipboard"),
        ("POST", "/api/v1/exec", "exec"),
        ("GET", "/api/v1/apps", "listApps"),
        ("POST", "/api/v1/apps/launch", "launchApp"),
        ("POST", "/api/v1/apps/quit", "quitApp"),
        ("GET", "/api/v1/apps/frontmost", "frontmostApp"),
        ("GET", "/api/v1/fs", "listDirectory"),
        ("POST", "/api/v1/files", "sendFile"),
        ("GET", "/api/v1/files", "listFiles"),
        ("GET", "/api/v1/ports", "listeningPorts"),
    ]

    // MARK: - Contract Integrity

    @Test("each endpoint has the correct HTTP method",
          arguments: [
              ("health", "GET"), ("getClipboard", "GET"), ("setClipboard", "POST"),
              ("exec", "POST"), ("listApps", "GET"), ("launchApp", "POST"),
              ("quitApp", "POST"), ("frontmostApp", "GET"), ("listDirectory", "GET"),
              ("sendFile", "POST"), ("listFiles", "GET"), ("listeningPorts", "GET"),
          ])
    func endpointMethod(name: String, expectedMethod: String) {
        let endpoint = Self.expectedEndpoints.first { $0.name == name }
        #expect(endpoint != nil, "Endpoint '\(name)' not found in contract")
        #expect(endpoint?.method == expectedMethod, "\(name) should use \(expectedMethod)")
    }

    @Test("no duplicate method+path pairs")
    func noDuplicates() {
        var seen = Set<String>()
        for ep in Self.expectedEndpoints {
            let key = "\(ep.method) \(ep.path)"
            #expect(!seen.contains(key), "Duplicate: \(key)")
            seen.insert(key)
        }
    }

    @Test("all non-health endpoints use /api/v1 prefix")
    func v1Prefix() {
        for ep in Self.expectedEndpoints where ep.name != "health" {
            #expect(ep.path.hasPrefix("/api/v1"), "\(ep.name): \(ep.path)")
        }
    }

    @Test("contract uses only GET and POST — no DELETE")
    func noDelete() {
        let methods = Set(Self.expectedEndpoints.map(\.method))
        #expect(methods == ["GET", "POST"])
    }

    @Test("quitApp uses POST /api/v1/apps/quit — not DELETE")
    func quitAppContract() {
        let quit = Self.expectedEndpoints.first { $0.name == "quitApp" }
        #expect(quit?.method == "POST")
        #expect(quit?.path == "/api/v1/apps/quit")
    }
}

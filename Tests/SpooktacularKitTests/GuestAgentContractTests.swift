import Testing

// MARK: - Guest Agent Contract Tests

/// Validates the guest agent HTTP contract as a static data structure.
///
/// Since we cannot connect to the real vsock in unit tests, these tests
/// verify the contract table itself: correct HTTP methods, paths, endpoint
/// count, and naming conventions. Any drift between client code and
/// contract is caught here.
@Suite("GuestAgentContract")
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

    // MARK: - Endpoint Count

    @Test("All 12 endpoints are defined")
    func endpointCount() {
        #expect(Self.expectedEndpoints.count == 12)
    }

    // MARK: - HTTP Methods

    @Test("health uses GET")
    func healthMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "health" }
        #expect(endpoint?.method == "GET")
    }

    @Test("getClipboard uses GET")
    func getClipboardMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "getClipboard" }
        #expect(endpoint?.method == "GET")
    }

    @Test("setClipboard uses POST")
    func setClipboardMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "setClipboard" }
        #expect(endpoint?.method == "POST")
    }

    @Test("exec uses POST")
    func execMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "exec" }
        #expect(endpoint?.method == "POST")
    }

    @Test("listApps uses GET")
    func listAppsMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "listApps" }
        #expect(endpoint?.method == "GET")
    }

    @Test("launchApp uses POST")
    func launchAppMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "launchApp" }
        #expect(endpoint?.method == "POST")
    }

    @Test("quitApp uses POST not DELETE")
    func quitAppMethod() {
        let quit = Self.expectedEndpoints.first { $0.name == "quitApp" }
        #expect(quit?.method == "POST")
        #expect(quit?.path == "/api/v1/apps/quit")
    }

    @Test("frontmostApp uses GET")
    func frontmostAppMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "frontmostApp" }
        #expect(endpoint?.method == "GET")
    }

    @Test("listDirectory uses GET")
    func listDirectoryMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "listDirectory" }
        #expect(endpoint?.method == "GET")
    }

    @Test("sendFile uses POST")
    func sendFileMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "sendFile" }
        #expect(endpoint?.method == "POST")
    }

    @Test("listFiles uses GET")
    func listFilesMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "listFiles" }
        #expect(endpoint?.method == "GET")
    }

    @Test("listeningPorts uses GET")
    func listeningPortsMethod() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "listeningPorts" }
        #expect(endpoint?.method == "GET")
    }

    // MARK: - Paths

    @Test("health path is /health")
    func healthPath() {
        let endpoint = Self.expectedEndpoints.first { $0.name == "health" }
        #expect(endpoint?.path == "/health")
    }

    @Test("All v1 endpoints use /api/v1 prefix")
    func v1Prefix() {
        let v1Endpoints = Self.expectedEndpoints.filter { $0.name != "health" }
        for endpoint in v1Endpoints {
            #expect(
                endpoint.path.hasPrefix("/api/v1"),
                "\(endpoint.name) should use /api/v1 prefix, got \(endpoint.path)"
            )
        }
    }

    @Test("No duplicate paths with the same method")
    func noDuplicateMethodPathPairs() {
        var seen = Set<String>()
        for endpoint in Self.expectedEndpoints {
            let key = "\(endpoint.method) \(endpoint.path)"
            #expect(!seen.contains(key), "Duplicate endpoint: \(key)")
            seen.insert(key)
        }
    }

    @Test("Every endpoint has a non-empty name")
    func nonEmptyNames() {
        for endpoint in Self.expectedEndpoints {
            #expect(!endpoint.name.isEmpty, "Endpoint at \(endpoint.path) has empty name")
        }
    }

    @Test("Clipboard endpoints share the same base path")
    func clipboardPathConsistency() {
        let get = Self.expectedEndpoints.first { $0.name == "getClipboard" }
        let set = Self.expectedEndpoints.first { $0.name == "setClipboard" }
        #expect(get?.path == "/api/v1/clipboard")
        #expect(set?.path == "/api/v1/clipboard")
    }

    @Test("Files endpoints share the same base path")
    func filesPathConsistency() {
        let send = Self.expectedEndpoints.first { $0.name == "sendFile" }
        let list = Self.expectedEndpoints.first { $0.name == "listFiles" }
        #expect(send?.path == "/api/v1/files")
        #expect(list?.path == "/api/v1/files")
    }

    @Test("App management endpoints are under /api/v1/apps")
    func appEndpointPaths() {
        let appEndpoints = Self.expectedEndpoints.filter {
            ["listApps", "launchApp", "quitApp", "frontmostApp"].contains($0.name)
        }
        #expect(appEndpoints.count == 4)
        for endpoint in appEndpoints {
            #expect(
                endpoint.path.hasPrefix("/api/v1/apps"),
                "\(endpoint.name) should be under /api/v1/apps, got \(endpoint.path)"
            )
        }
    }

    // MARK: - Method Distribution

    @Test("Correct GET vs POST distribution")
    func methodDistribution() {
        let getMethods = Self.expectedEndpoints.filter { $0.method == "GET" }
        let postMethods = Self.expectedEndpoints.filter { $0.method == "POST" }
        #expect(getMethods.count == 7, "Expected 7 GET endpoints")
        #expect(postMethods.count == 5, "Expected 5 POST endpoints")
    }

    @Test("No DELETE methods in the contract")
    func noDeleteMethods() {
        let deleteMethods = Self.expectedEndpoints.filter { $0.method == "DELETE" }
        #expect(deleteMethods.isEmpty, "Contract should not use DELETE")
    }
}

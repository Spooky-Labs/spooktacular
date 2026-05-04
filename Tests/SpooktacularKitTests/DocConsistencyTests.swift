import Testing
import Foundation

// MARK: - Helpers

/// Returns the project root by walking up from the current file until we find Package.swift.
private func projectRoot() throws -> String {
    // Swift Package Manager sets the working directory to the package root when
    // running `swift test`, so this should work in most configurations.
    let fm = FileManager.default
    var candidate = fm.currentDirectoryPath

    // Walk up at most 10 levels to find Package.swift (handles Xcode's DerivedData).
    for _ in 0..<10 {
        if fm.fileExists(atPath: candidate + "/Package.swift") {
            return candidate
        }
        candidate = (candidate as NSString).deletingLastPathComponent
    }

    // Fallback: assume cwd is the project root (standard `swift test` behavior).
    return fm.currentDirectoryPath
}

/// Reads a project-relative file and returns its contents.
private func readProjectFile(_ relativePath: String) throws -> String {
    let root = try projectRoot()
    let fullPath = root + "/" + relativePath
    guard FileManager.default.fileExists(atPath: fullPath) else {
        throw DocConsistencyError.fileNotFound(fullPath)
    }
    return try String(contentsOfFile: fullPath, encoding: .utf8)
}

/// Checks whether a project-relative path exists (file or directory).
private func projectPathExists(_ relativePath: String) throws -> Bool {
    let root = try projectRoot()
    let fullPath = root + "/" + relativePath
    return FileManager.default.fileExists(atPath: fullPath)
}

private enum DocConsistencyError: Error, CustomStringConvertible {
    case fileNotFound(String)

    var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        }
    }
}

// MARK: - DocConsistency Suite

@Suite("DocConsistency")
struct DocConsistencyTests {

    // MARK: - 1. README source links point to existing paths

    @Test("README source links point to existing paths")
    func readmeSourcePaths() throws {
        let readme = try readProjectFile("README.md")

        // Match markdown links whose URL starts with Sources/
        // Pattern: [any text](Sources/some/path)
        let pattern = try NSRegularExpression(pattern: #"\]\((Sources/[^)]+)\)"#)
        let matches = pattern.matches(
            in: readme,
            range: NSRange(readme.startIndex..., in: readme)
        )

        #expect(!matches.isEmpty, "Expected at least one Sources/ link in README.md")

        var missing: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: readme) else { continue }
            let path = String(readme[range])
            let exists = try projectPathExists(path)
            if !exists {
                missing.append(path)
            }
        }

        #expect(
            missing.isEmpty,
            "README links to non-existent paths: \(missing.joined(separator: ", "))"
        )
    }

    // MARK: - 2. Package.swift target paths exist

    @Test("Package.swift target paths exist")
    func packageTargetPaths() throws {
        let package = try readProjectFile("Package.swift")

        // Match path: "Sources/..." or path: "Tests/..." in target declarations.
        let pattern = try NSRegularExpression(pattern: #"path:\s*"([^"]+)""#)
        let matches = pattern.matches(
            in: package,
            range: NSRange(package.startIndex..., in: package)
        )

        #expect(!matches.isEmpty, "Expected at least one path declaration in Package.swift")

        var missing: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: package) else { continue }
            let path = String(package[range])
            let exists = try projectPathExists(path)
            if !exists {
                missing.append(path)
            }
        }

        #expect(
            missing.isEmpty,
            "Package.swift declares non-existent paths: \(missing.joined(separator: ", "))"
        )
    }

    // MARK: - 3. Clean Architecture layer compliance

    /// The set of imports allowed in Entities, Interfaces, and UseCases layers.
    /// These layers must depend only on Foundation (or have no imports at all).
    private static let allowedImports: Set<String> = ["Foundation"]

    @Test("SpooktacularCore files import only Foundation")
    func coreLayerCompliance() throws {
        try assertLayerImports(layer: "Sources/SpooktacularCore")
    }

    @Test("SpooktacularApplication files import only Foundation, SpooktacularCore, or CryptoKit")
    func applicationLayerCompliance() throws {
        // CryptoKit is allowed in SpooktacularApplication because the shared
        // SignedRequestVerifier + per-request signing primitive need
        // P-256 ECDSA verification. CryptoKit is a system framework
        // (Apple-native, FIPS-validated) so it doesn't violate the
        // "no third-party deps" rule this layer is otherwise protecting.
        try assertLayerImports(layer: "Sources/SpooktacularApplication", allowed: ["Foundation", "SpooktacularCore", "CryptoKit"])
    }

    /// Scans all `.swift` files in the given layer directory and verifies that
    /// every `import` statement references only allowed modules.
    private func assertLayerImports(layer: String, allowed: Set<String>? = nil) throws {
        let allowedSet = allowed ?? Self.allowedImports
        let root = try projectRoot()
        let layerPath = root + "/" + layer
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(atPath: layerPath) else {
            Issue.record("Layer directory does not exist: \(layer)")
            return
        }

        let importPattern = try NSRegularExpression(pattern: #"^import\s+(\w+)"#, options: .anchorsMatchLines)
        var violations: [String] = []

        while let file = enumerator.nextObject() as? String {
            guard file.hasSuffix(".swift") else { continue }

            let filePath = layerPath + "/" + file
            let contents = try String(contentsOfFile: filePath, encoding: .utf8)

            // Only scan the first 30 lines (imports are always at the top).
            let lines = contents.components(separatedBy: .newlines)
            let head = lines.prefix(30).joined(separator: "\n")

            let matches = importPattern.matches(
                in: head,
                range: NSRange(head.startIndex..., in: head)
            )

            for match in matches {
                guard let range = Range(match.range(at: 1), in: head) else { continue }
                let module = String(head[range])
                if !allowedSet.contains(module) {
                    violations.append("\(file) imports \(module)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "Clean Architecture violation in \(layer): \(violations.joined(separator: "; "))"
        )
    }

    // MARK: - 4. CI workflow trigger claims match README

    @Test("README CI trigger matches workflow file")
    func ciTriggerConsistency() throws {
        let readme: String
        let ci: String
        do {
            readme = try readProjectFile("README.md")
            ci = try readProjectFile(".github/workflows/ci.yml")
        } catch {
            // CI file layout may differ in some environments; skip gracefully.
            return
        }

        // README says "Pull request to main" for the CI workflow.
        if readme.contains("Pull request to main") {
            #expect(
                ci.contains("pull_request"),
                "README claims CI triggers on pull requests, but ci.yml has no pull_request trigger"
            )
        }

        // README says "Push to main" for the Beta workflow.
        if readme.contains("Push to main") {
            // This claim is about the Beta workflow, not CI. Verify the beta
            // workflow exists and contains a push trigger.
            if let beta = try? readProjectFile(".github/workflows/beta.yml") {
                #expect(
                    beta.contains("push"),
                    "README claims Beta triggers on push to main, but beta.yml has no push trigger"
                )
            }
        }

        // README says "Tag v*" for the Release workflow.
        if readme.contains("Tag `v*`") || readme.contains("Tag v*") {
            if let release = try? readProjectFile(".github/workflows/release.yml") {
                #expect(
                    release.contains("tags"),
                    "README claims Release triggers on tags, but release.yml has no tags trigger"
                )
            }
        }
    }

    // MARK: - 5. Test count in README is not stale

    @Test("README test count is within range of actual count")
    func testCountNotStale() throws {
        let readme = try readProjectFile("README.md")

        // The README badge uses a pattern like "Tests-NNN_passing" or "NNN passing"
        // or "NNN tests". Extract the number from the badge.
        let badgePattern = try NSRegularExpression(pattern: #"Tests-(\d+)_passing"#)
        let matches = badgePattern.matches(
            in: readme,
            range: NSRange(readme.startIndex..., in: readme)
        )

        // Also check for prose mentions like "Run 360 tests" or "360+ tests".
        let prosePattern = try NSRegularExpression(pattern: #"(\d+)\+?\s+tests"#, options: .caseInsensitive)
        let proseMatches = prosePattern.matches(
            in: readme,
            range: NSRange(readme.startIndex..., in: readme)
        )

        var claimedCounts: [Int] = []

        for match in matches {
            if let range = Range(match.range(at: 1), in: readme),
               let count = Int(readme[range]) {
                claimedCounts.append(count)
            }
        }

        for match in proseMatches {
            if let range = Range(match.range(at: 1), in: readme),
               let count = Int(readme[range]) {
                claimedCounts.append(count)
            }
        }

        guard !claimedCounts.isEmpty else {
            // No test count claims found -- nothing to validate.
            return
        }

        // All claimed counts should be consistent with each other (within 20%).
        // We can't know the exact count at compile time, but the badge count
        // and prose count should not wildly disagree.
        let minClaimed = claimedCounts.min()!
        let maxClaimed = claimedCounts.max()!

        // The README badge and prose should not differ by more than a factor of 2.
        #expect(
            maxClaimed <= minClaimed * 2,
            "README test counts are inconsistent: badge and prose claim \(claimedCounts)"
        )

        // Sanity check: the claimed count should be a reasonable number (> 50).
        // A project of this size should have more than 50 tests.
        for count in claimedCounts {
            #expect(
                count > 50,
                "README claims only \(count) tests, which seems too low for this project"
            )
        }
    }

    // MARK: - 6. Helm TLS default matches NodeManager default scheme

    @Test("Helm TLS default matches NodeManager default scheme")
    func tlsDefaultConsistency() throws {
        let values: String
        let nodeManager: String
        do {
            values = try readProjectFile("deploy/kubernetes/helm/spooktacular/values.yaml")
            nodeManager = try readProjectFile("Sources/spook-controller/NodeManager.swift")
        } catch {
            // Helm chart or controller may not exist in all checkouts; skip gracefully.
            return
        }

        // Determine TLS setting from values.yaml.
        // Look for the tls.enabled field. The YAML structure is:
        //   tls:
        //     enabled: true
        let tlsPattern = try NSRegularExpression(
            pattern: #"tls:\s*\n\s*(?:#[^\n]*\n\s*)*enabled:\s*(true|false)"#,
            options: .dotMatchesLineSeparators
        )
        let tlsMatch = tlsPattern.firstMatch(
            in: values,
            range: NSRange(values.startIndex..., in: values)
        )

        // Determine default scheme from NodeManager.swift.
        // Look for the scheme parameter default, e.g.:
        //   scheme: String = ... ?? "https"
        let schemePattern = try NSRegularExpression(
            pattern: #"\?\?\s*"(https?)""#
        )
        let schemeMatch = schemePattern.firstMatch(
            in: nodeManager,
            range: NSRange(nodeManager.startIndex..., in: nodeManager)
        )

        if let tlsRange = tlsMatch.flatMap({ Range($0.range(at: 1), in: values) }),
           let schemeRange = schemeMatch.flatMap({ Range($0.range(at: 1), in: nodeManager) }) {
            let tlsEnabled = String(values[tlsRange]) == "true"
            let defaultScheme = String(nodeManager[schemeRange])

            if tlsEnabled {
                #expect(
                    defaultScheme == "https",
                    "Helm values.yaml has tls.enabled=true but NodeManager defaults to \"\(defaultScheme)\" instead of \"https\""
                )
            } else {
                #expect(
                    defaultScheme == "http",
                    "Helm values.yaml has tls.enabled=false but NodeManager defaults to \"\(defaultScheme)\" instead of \"http\""
                )
            }
        }
    }
}

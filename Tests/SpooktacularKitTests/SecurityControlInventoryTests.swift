import Testing
import Foundation
@testable import SpooktacularKit

/// Pins the integrity of the `spook security-controls` inventory.
///
/// The inventory is hand-curated — it's what a reviewer walks
/// through during an audit, so drift between "documented control"
/// and "actual file location" directly translates into wasted
/// reviewer time. These tests fail fast when:
///
/// 1. A cited implementation path doesn't exist
/// 2. A cited test file doesn't exist (when one is cited)
/// 3. Two entries accidentally share the same `name`
/// 4. Any field is empty where the inventory's contract says it
///    shouldn't be
///
/// The repository root is derived from `#filePath` so the tests
/// run correctly under `swift test` regardless of working
/// directory.
@Suite("Security control inventory", .tags(.security))
struct SecurityControlInventoryTests {

    /// Repo root relative to this test file.
    /// `…/Tests/SpooktacularKitTests/SecurityControlInventoryTests.swift`
    /// → three `deletingLastPathComponent()`s back to the root.
    private static let repoRoot: URL = {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    @Test("every inventory entry's implementation path exists on disk")
    func implementationsExist() {
        let fm = FileManager.default
        // Accept these extensions as "the path part"; anything
        // after a `.swift/.sh/.json` segment is a method/detail
        // qualifier and gets trimmed off before the existence
        // check.
        let extensions = [".swift", ".sh", ".json", ".yml"]

        for control in SecurityControlInventory.all {
            let rawCandidates = control.implementation
                .split(separator: "+")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            var paths: [String] = []
            for chunk in rawCandidates {
                // Take the first whitespace-delimited token —
                // that's the path. Then find the first `.swift`
                // (or friends) and truncate there.
                let firstToken = chunk.split(separator: " ").first.map(String.init) ?? chunk
                var best: String?
                for ext in extensions {
                    if let range = firstToken.range(of: ext) {
                        best = String(firstToken[..<range.upperBound])
                        break
                    }
                }
                if let best { paths.append(best) }
            }

            #expect(!paths.isEmpty,
                    "\(control.name): no parseable file path in '\(control.implementation)'")
            for relative in paths {
                let path = Self.repoRoot.appendingPathComponent(relative).path
                #expect(fm.fileExists(atPath: path),
                        "\(control.name): implementation path '\(relative)' not found")
            }
        }
    }

    @Test("every cited test file exists on disk")
    func testsExist() {
        let fm = FileManager.default
        for control in SecurityControlInventory.all {
            guard let testPath = control.test else { continue }
            let path = Self.repoRoot.appendingPathComponent(testPath).path
            #expect(fm.fileExists(atPath: path),
                    "\(control.name): test file '\(testPath)' not found")
        }
    }

    @Test("every inventory entry has non-empty name / category / standard / implementation")
    func requiredFieldsPopulated() {
        for control in SecurityControlInventory.all {
            #expect(!control.name.isEmpty)
            #expect(!control.category.isEmpty)
            #expect(!control.standard.isEmpty)
            #expect(!control.implementation.isEmpty)
        }
    }

    @Test("no two inventory entries share a name")
    func namesAreUnique() {
        let names = SecurityControlInventory.all.map(\.name)
        let unique = Set(names)
        #expect(names.count == unique.count,
                "Duplicate control names detected: \(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys)")
    }

    @Test("inventory has at least one entry in each expected category")
    func categoriesArePresent() {
        let categories = Set(SecurityControlInventory.all.map(\.category))
        let expected: Set<String> = [
            "Authentication & Identity",
            "Authorization",
            "Break-Glass",
            "Audit & Non-Repudiation",
            "Data at Rest",
        ]
        let missing = expected.subtracting(categories)
        #expect(missing.isEmpty,
                "Inventory missing controls in categories: \(missing)")
    }
}

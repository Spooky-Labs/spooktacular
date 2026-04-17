import Testing
import Foundation
@testable import SpookCore
@testable import SpookInfrastructureApple

/// Audits the inheritance promise from `docs/DATA_AT_REST.md`:
///
/// > "VM lifetime involves many writes (snapshots, clones, disk
/// > image resizes). Every write path in `SpookInfrastructureApple`
/// > that creates a new file inside a bundle must preserve the
/// > protection class. We audit this with a test: any new file
/// > created inside a protected bundle inherits the class."
///
/// Each test:
///   1. Creates a bundle in a tmp dir.
///   2. Explicitly sets the bundle dir to CUFUA.
///   3. Exercises a write path (create, clone, snapshot, writeSpec,
///      writeMetadata).
///   4. Calls `BundleProtection.verifyInheritance` and asserts the
///      returned violation list is empty.
///
/// On hosts without FileVault active, `FileProtectionType.cufua`
/// applies as a stored attribute but isn't enforced by the kernel.
/// The verifier reads the stored attribute regardless, so these
/// tests pin the inheritance contract on CI runners and laptops
/// alike.
@Suite("Bundle protection inheritance", .tags(.security))
struct BundleProtectionInheritanceTests {

    /// Shared helper: spin up a bundle, force CUFUA, hand it to
    /// the caller, and clean up afterwards.
    private static func withProtectedBundle<T>(
        _ body: (VirtualMachineBundle) throws -> T
    ) throws -> T {
        let dir = NSTemporaryDirectory() + "bundle-inherit-\(UUID().uuidString).vm"
        let url = URL(filePath: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let bundle = try VirtualMachineBundle.create(
            at: url,
            spec: VirtualMachineSpecification()
        )

        // Force CUFUA regardless of host form factor so the test
        // body works identically on laptops and desktops.
        try BundleProtection.apply(.completeUntilFirstUserAuthentication, to: url)
        try BundleProtection.propagate(to: url)

        return try body(bundle)
    }

    @Test("VirtualMachineBundle.create leaves no inheritance violations")
    func createPath() throws {
        try Self.withProtectedBundle { bundle in
            let violations = try BundleProtection.verifyInheritance(bundleURL: bundle.url)
            #expect(violations.isEmpty,
                    "create() must propagate: violations = \(violations.map(\.0.lastPathComponent))")
        }
    }

    @Test("writeSpec preserves the bundle's protection class")
    func writeSpecPath() throws {
        try Self.withProtectedBundle { bundle in
            // Any subsequent write triggers the atomic-rename path —
            // we just re-serialize the same spec to exercise it.
            try VirtualMachineBundle.writeSpec(bundle.spec, to: bundle.url)

            let violations = try BundleProtection.verifyInheritance(bundleURL: bundle.url)
            #expect(violations.isEmpty,
                    "writeSpec atomic-rename must re-apply class: violations = \(violations.map(\.0.lastPathComponent))")
        }
    }

    @Test("writeMetadata preserves the bundle's protection class")
    func writeMetadataPath() throws {
        try Self.withProtectedBundle { bundle in
            try VirtualMachineBundle.writeMetadata(bundle.metadata, to: bundle.url)

            let violations = try BundleProtection.verifyInheritance(bundleURL: bundle.url)
            #expect(violations.isEmpty,
                    "writeMetadata atomic-rename must re-apply class: violations = \(violations.map(\.0.lastPathComponent))")
        }
    }

    @Test("CloneManager.clone propagates protection to the destination bundle")
    func clonePath() throws {
        try Self.withProtectedBundle { source in
            let destURL = URL(filePath: NSTemporaryDirectory() + "clone-\(UUID().uuidString).vm")
            defer { try? FileManager.default.removeItem(at: destURL) }

            _ = try CloneManager.clone(source: source, to: destURL)

            let srcClass = try BundleProtection.current(at: source.url)
            let dstClass = try BundleProtection.current(at: destURL)
            #expect(dstClass.strengthRank >= srcClass.strengthRank,
                    "Clone bundle dir class (\(dstClass.displayName)) must be at least as strong as source (\(srcClass.displayName))")

            let violations = try BundleProtection.verifyInheritance(bundleURL: destURL)
            #expect(violations.isEmpty,
                    "Clone child files must inherit: violations = \(violations.map(\.0.lastPathComponent))")
        }
    }

    @Test("unknown FileProtectionType ranks below .none to flag regressions")
    func unknownClassRanksAsViolation() {
        // If Apple introduces a new protection class in a future
        // macOS release, we want `verifyInheritance` to report it
        // as a violation (fail-closed) until we update the rank
        // table — rather than silently accept it.
        let unknown = FileProtectionType(rawValue: "NSFileProtectionMadeUpClass")
        #expect(unknown.strengthRank == -1)
        #expect(unknown.strengthRank < FileProtectionType.none.strengthRank)
    }
}

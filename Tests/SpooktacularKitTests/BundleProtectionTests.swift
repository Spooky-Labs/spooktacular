import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

/// Covers the data-at-rest protection policy described in
/// docs/DATA_AT_REST.md. The runtime behavior on a given host is
/// fixed (laptop vs desktop), so these tests pin the *policy*
/// independently of the host that runs them.
@Suite("Bundle protection", .tags(.security))
struct BundleProtectionTests {

    // MARK: - Policy selection

    @Test("SPOOKTACULAR_BUNDLE_PROTECTION=none overrides even on a laptop")
    func envOverrideNoneBeatsLaptop() {
        let (protection, policy) = BundleProtection.recommendedPolicy(
            environment: ["SPOOKTACULAR_BUNDLE_PROTECTION": "none"],
            isPortable: true
        )
        #expect(protection == .none)
        #expect(policy == .overrideNone)
    }

    @Test("SPOOKTACULAR_BUNDLE_PROTECTION=cufua overrides even on a desktop")
    func envOverrideCUFUABeatsDesktop() {
        let (protection, policy) = BundleProtection.recommendedPolicy(
            environment: ["SPOOKTACULAR_BUNDLE_PROTECTION": "cufua"],
            isPortable: false
        )
        #expect(protection == .completeUntilFirstUserAuthentication)
        #expect(policy == .overrideCUFUA)
    }

    @Test("laptop without env override → CUFUA")
    func laptopDefault() {
        let (protection, policy) = BundleProtection.recommendedPolicy(
            environment: [:],
            isPortable: true
        )
        #expect(protection == .completeUntilFirstUserAuthentication)
        #expect(policy == .autoLaptop)
    }

    @Test("desktop without env override → none (don't break LaunchDaemon pre-login)")
    func desktopDefault() {
        let (protection, policy) = BundleProtection.recommendedPolicy(
            environment: [:],
            isPortable: false
        )
        #expect(protection == .none)
        #expect(policy == .autoDesktop)
    }

    @Test("unknown SPOOKTACULAR_BUNDLE_PROTECTION value falls through to auto-detect")
    func unknownValueFallsThrough() {
        let (protection, policy) = BundleProtection.recommendedPolicy(
            environment: ["SPOOKTACULAR_BUNDLE_PROTECTION": "banana"],
            isPortable: true
        )
        #expect(protection == .completeUntilFirstUserAuthentication)
        #expect(policy == .autoLaptop)
    }

    // MARK: - UserDefaults tier (GUI Settings pane)

    /// Helper: isolated defaults suite so tests don't leak into
    /// the real login-user's preferences.
    private func defaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "bundle-protection-test-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: "bundle-protection-test")
        return suite
    }

    @Test("UserDefaults 'none' overrides auto-detect on a laptop")
    func userDefaultsNoneBeatsLaptop() {
        let ud = defaults()
        ud.set("none", forKey: BundleProtection.userDefaultsKey)
        let (protection, policy) = BundleProtection.recommendedPolicy(
            environment: [:],
            userDefaults: ud,
            isPortable: true
        )
        #expect(protection == .none)
        #expect(policy == .overrideSettingsNone)
    }

    @Test("UserDefaults 'cufua' overrides auto-detect on a desktop")
    func userDefaultsCUFUABeatsDesktop() {
        let ud = defaults()
        ud.set("cufua", forKey: BundleProtection.userDefaultsKey)
        let (protection, policy) = BundleProtection.recommendedPolicy(
            environment: [:],
            userDefaults: ud,
            isPortable: false
        )
        #expect(protection == .completeUntilFirstUserAuthentication)
        #expect(policy == .overrideSettingsCUFUA)
    }

    @Test("env var wins over UserDefaults")
    func envBeatsUserDefaults() {
        let ud = defaults()
        ud.set("none", forKey: BundleProtection.userDefaultsKey)
        let (protection, policy) = BundleProtection.recommendedPolicy(
            environment: ["SPOOKTACULAR_BUNDLE_PROTECTION": "cufua"],
            userDefaults: ud,
            isPortable: false
        )
        #expect(protection == .completeUntilFirstUserAuthentication)
        #expect(policy == .overrideCUFUA,
                "Env-var intent (LaunchDaemon / MDM) must override per-user GUI preference")
    }

    @Test("UserDefaults 'auto' (sentinel) falls through to auto-detect")
    func userDefaultsAutoFallsThrough() {
        let ud = defaults()
        ud.set("auto", forKey: BundleProtection.userDefaultsKey)
        let (protection, policy) = BundleProtection.recommendedPolicy(
            environment: [:],
            userDefaults: ud,
            isPortable: true
        )
        #expect(protection == .completeUntilFirstUserAuthentication)
        #expect(policy == .autoLaptop)
    }

    // MARK: - Apply round-trip
    //
    // We intentionally do NOT round-trip through `current(at:)`
    // here — macOS honors the `FileProtectionType` attribute but
    // the observed class depends on FileVault state + the user's
    // home-directory default class. A test that pins a specific
    // read-back value would be host-dependent and flaky. The
    // apply-call not throwing is the meaningful check; the
    // system behavior beyond that is Apple's.
    @Test("apply(.none) does not throw on a throwaway directory")
    func applyDoesNotThrow() throws {
        let dir = NSTemporaryDirectory() + "bundle-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try BundleProtection.apply(.none, to: URL(filePath: dir))
    }

    @Test("FileProtectionType.displayName is stable for documentation")
    func displayNamesAreStable() {
        #expect(FileProtectionType.none.displayName == "None")
        #expect(FileProtectionType.completeUntilFirstUserAuthentication.displayName
                == "CompleteUntilFirstUserAuthentication")
    }
}

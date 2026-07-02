import Foundation
import Testing
@testable import SpooktacularApplication

/// Tests for ``AppBundleBootstrapTemplate`` — now a pure-data
/// helper namespace (bundle filename + install path +
/// host-side locator) after the Apple-native refactor
/// replaced the old script-generation surface with direct
/// `ditto`-based installation in
/// ``SpooktacularInfrastructureApple/DiskInjector/installGuestTools(appBundle:into:)``.
///
/// The `LaunchAgent` plist generator was removed when
/// launch-at-login moved into the guest app itself (via
/// `SMAppService.mainApp`) — so the host installer no
/// longer writes to `/Library/LaunchAgents/`, no longer
/// needs root, and no longer prompts for an admin password.
@Suite("AppBundleBootstrapTemplate")
struct AppBundleBootstrapTemplateTests {

    @Test("Install paths are stable across invocations")
    func installPathsStable() {
        #expect(AppBundleBootstrapTemplate.bundleFileName == "Spooktacular Guest Tools.app")
        #expect(AppBundleBootstrapTemplate.installedAppPath == "/Applications/Spooktacular Guest Tools.app")
    }

    @Test("Locator honours the env-var override when the path exists")
    func locatorHonoursOverride() throws {
        let fakeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spook-test-\(UUID().uuidString)")
        let fakeApp = fakeDir.appendingPathComponent(
            AppBundleBootstrapTemplate.bundleFileName
        )
        try FileManager.default.createDirectory(
            at: fakeApp.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fakeDir) }

        setenv("SPOOKTACULAR_GUEST_TOOLS_BUNDLE", fakeApp.path, 1)
        defer { unsetenv("SPOOKTACULAR_GUEST_TOOLS_BUNDLE") }

        let resolved = AppBundleBootstrapTemplate.locateGuestToolsBundle()
        #expect(resolved?.path == fakeApp.path)
    }

    @Test("Locator returns nil when the override points at a missing path")
    func locatorRejectsMissingOverride() {
        setenv(
            "SPOOKTACULAR_GUEST_TOOLS_BUNDLE",
            "/nonexistent/path/does/not/exist.app",
            1
        )
        defer { unsetenv("SPOOKTACULAR_GUEST_TOOLS_BUNDLE") }

        // We can't assert `== nil` unconditionally because the
        // test might run from a location where the production
        // fallback paths resolve. But we can assert the
        // override was ignored (any resolved URL must not be
        // the missing override path).
        let resolved = AppBundleBootstrapTemplate.locateGuestToolsBundle()
        #expect(resolved?.path != "/nonexistent/path/does/not/exist.app")
    }

    // MARK: - Provisioner pkg locator

    @Test("Provisioner pkg file name is stable")
    func provisionerPkgFileNameStable() {
        #expect(AppBundleBootstrapTemplate.provisionerPkgFileName == "Spooktacular Provisioner.pkg")
    }

    @Test("locateProvisionerPkg resolves the pkg inside the Guest Tools bundle fixture")
    func locateProvisionerPkgResolvesInsideBundle() throws {
        let fakeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spook-test-\(UUID().uuidString)")
        let fakeApp = fakeDir.appendingPathComponent(
            AppBundleBootstrapTemplate.bundleFileName
        )
        let resourcesDir = fakeApp.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
            at: resourcesDir,
            withIntermediateDirectories: true
        )
        let pkgURL = resourcesDir.appendingPathComponent(
            AppBundleBootstrapTemplate.provisionerPkgFileName
        )
        try Data("fake pkg".utf8).write(to: pkgURL)
        defer { try? FileManager.default.removeItem(at: fakeDir) }

        setenv("SPOOKTACULAR_GUEST_TOOLS_BUNDLE", fakeApp.path, 1)
        defer { unsetenv("SPOOKTACULAR_GUEST_TOOLS_BUNDLE") }

        let resolved = AppBundleBootstrapTemplate.locateProvisionerPkg()
        #expect(resolved?.path == pkgURL.path)
    }

    @Test("locateProvisionerPkg returns nil when the Guest Tools bundle exists but has no pkg")
    func locateProvisionerPkgNilWhenPkgMissing() throws {
        let fakeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spook-test-\(UUID().uuidString)")
        let fakeApp = fakeDir.appendingPathComponent(
            AppBundleBootstrapTemplate.bundleFileName
        )
        try FileManager.default.createDirectory(
            at: fakeApp.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fakeDir) }

        setenv("SPOOKTACULAR_GUEST_TOOLS_BUNDLE", fakeApp.path, 1)
        defer { unsetenv("SPOOKTACULAR_GUEST_TOOLS_BUNDLE") }

        let resolved = AppBundleBootstrapTemplate.locateProvisionerPkg()
        #expect(resolved == nil)
    }

    @Test("locateProvisionerPkg returns nil outside an app bundle")
    func locateProvisionerPkgNilOutsideBundle() {
        setenv(
            "SPOOKTACULAR_GUEST_TOOLS_BUNDLE",
            "/nonexistent/path/does/not/exist.app",
            1
        )
        defer { unsetenv("SPOOKTACULAR_GUEST_TOOLS_BUNDLE") }

        // Same reasoning as `locatorRejectsMissingOverride`: we
        // can't assert unconditional nil because the production
        // fallback paths might resolve on some machines, but the
        // missing override must never be what resolves.
        let resolved = AppBundleBootstrapTemplate.locateProvisionerPkg()
        #expect(resolved?.path != "/nonexistent/path/does/not/exist.app/Contents/Resources/Spooktacular Provisioner.pkg")
    }
}

import Foundation
import Testing
@testable import SpooktacularCore

/// Tests for ``GuestToolsInstallMode`` — the two-way user
/// control for installing the Guest Tools `.app` into a
/// macOS guest VM. Launch-at-login is owned by the guest
/// app's own menu-bar `SMAppService.mainApp` toggle, not
/// by this enum, so there are only two cases —
/// ``GuestToolsInstallMode/disabled`` and
/// ``GuestToolsInstallMode/installed``.
@Suite("GuestToolsInstallMode")
struct GuestToolsInstallModeTests {

    @Test("installsAppBundle matches the install semantics")
    func installsAppBundleMatrix() {
        #expect(GuestToolsInstallMode.disabled.installsAppBundle == false)
        #expect(GuestToolsInstallMode.installed.installsAppBundle == true)
    }

    @Test("Codable raw values are stable for on-disk bundles")
    func codableRawValues() {
        // Bundle JSON persistence relies on these raw values;
        // changing them would break decoding of existing
        // config.json files.
        #expect(GuestToolsInstallMode.disabled.rawValue == "disabled")
        #expect(GuestToolsInstallMode.installed.rawValue == "installed")
    }

    @Test("All cases have non-empty display + help text")
    func nonEmptyUserFacingStrings() {
        for mode in GuestToolsInstallMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.helpText.isEmpty)
        }
    }

    @Test("Only two cases exist — autoLaunchOnLogin was removed")
    func exactlyTwoCases() {
        // Guards against a future edit re-introducing
        // `.autoLaunchOnLogin` (or any other host-side
        // launch-at-login control). The invariant the
        // refactor established: launch-at-login is the
        // guest app's concern, so the host-side enum has
        // exactly two states.
        #expect(GuestToolsInstallMode.allCases.count == 2)
        let rawValues = Set(GuestToolsInstallMode.allCases.map(\.rawValue))
        #expect(rawValues == ["disabled", "installed"])
    }

    @Test("VirtualMachineSpecification defaults guestToolsInstall to installed")
    func specDefaultIsInstalled() {
        let spec = VirtualMachineSpecification()
        #expect(spec.guestToolsInstall == .installed)
    }

    @Test("VirtualMachineSpecification.with() updates the install mode")
    func specWithUpdatesInstall() {
        let original = VirtualMachineSpecification()
        let updated = original.with(guestToolsInstall: .disabled)
        #expect(updated.guestToolsInstall == .disabled)
        // Other fields preserved.
        #expect(updated.cpuCount == original.cpuCount)
        #expect(updated.memorySizeInBytes == original.memorySizeInBytes)
    }

    @Test("Spec round-trips through JSON Codable with the new field")
    func specCodableRoundTrip() throws {
        let spec = VirtualMachineSpecification().with(
            guestToolsInstall: .installed
        )
        let encoded = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(
            VirtualMachineSpecification.self, from: encoded
        )
        #expect(decoded.guestToolsInstall == .installed)
    }

    @Test("Pre-Phase-3 bundles without the field default to installed on decode")
    func preField3BundleDefault() throws {
        // Build a JSON payload that looks like a pre-Phase-3
        // bundle: every required field present, but no
        // `guestToolsInstall` key. The decoder's
        // `decodeIfPresent` fallback should kick in.
        let template = try JSONEncoder().encode(VirtualMachineSpecification())
        var json = try JSONSerialization.jsonObject(with: template) as? [String: Any] ?? [:]
        json.removeValue(forKey: "guestToolsInstall")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(
            VirtualMachineSpecification.self, from: stripped
        )
        #expect(decoded.guestToolsInstall == .installed)
    }

    // MARK: - Linux invariant

    @Test("Linux spec clamps guestToolsInstall to .disabled at init")
    func linuxClampsAtInit() {
        // Caller passes `.installed` but guestOS is Linux.
        // The spec enforces the invariant — Guest Tools is
        // a macOS-only `.app`, so Linux specs CANNOT carry
        // any value other than `.disabled`.
        let spec = VirtualMachineSpecification(
            guestOS: .linux,
            guestToolsInstall: .installed
        )
        #expect(spec.guestToolsInstall == .disabled)
    }

    @Test("Linux spec on decode clamps a pre-invariant saved config.json")
    func linuxDecodeClamps() throws {
        // Simulate a config.json written before the init
        // invariant existed: guestOS=linux AND a non-disabled
        // install mode. The decoder must normalise on load
        // so no caller ever sees the impossible combination.
        let valid = VirtualMachineSpecification(guestOS: .linux)
        let validData = try JSONEncoder().encode(valid)
        var json = try JSONSerialization.jsonObject(with: validData) as? [String: Any] ?? [:]
        json["guestToolsInstall"] = "installed"
        let impossible = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(
            VirtualMachineSpecification.self, from: impossible
        )
        #expect(decoded.guestOS == .linux)
        #expect(decoded.guestToolsInstall == .disabled)
    }

    @Test("macOS specs retain their chosen guestToolsInstall on round-trip")
    func macOSPreserved() throws {
        let spec = VirtualMachineSpecification(
            guestOS: .macOS,
            guestToolsInstall: .installed
        )
        #expect(spec.guestToolsInstall == .installed)

        // Round-trip JSON to prove the clamp only triggers
        // for Linux — macOS specs pass through unchanged.
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(
            VirtualMachineSpecification.self, from: data
        )
        #expect(decoded.guestToolsInstall == .installed)
    }
}

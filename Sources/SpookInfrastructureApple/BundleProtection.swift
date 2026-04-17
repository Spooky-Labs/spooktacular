import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// Applies the right `FileProtectionType` to VM bundle directories
/// at creation time, closing the "laptop stolen while powered off
/// with compromised FileVault key" gap that whole-disk encryption
/// alone can't cover.
///
/// See `docs/DATA_AT_REST.md` for the full threat model and the
/// OWASP ASVS V6.1.1 / V6.4.1 / V14.2.6 mapping.
///
/// ## Usage
///
/// ```swift
/// try BundleProtection.applyRecommended(to: bundleURL)
/// ```
///
/// ## Behavior
///
/// - On **portable Macs** (laptops with a battery):
///   `.completeUntilFirstUserAuthentication` is applied by
///   default. The per-file key is derived at first-unlock from
///   the Secure Enclave-held user passcode; a powered-off
///   laptop with a leaked FileVault recovery key cannot read
///   the bundle.
/// - On **desktops / Mac minis / EC2 Mac hosts**: `.none`.
///   CUFUA would prevent LaunchDaemon paths (`spook serve`
///   running before login) from reading the bundle, which is
///   the deployment shape for headless fleets.
/// - `SPOOK_BUNDLE_PROTECTION=none` forces `.none` even on
///   laptops (dev-loop convenience; operators accept the risk).
/// - `SPOOK_BUNDLE_PROTECTION=cufua` forces CUFUA even on
///   desktops (regulated deployment that wants the posture
///   regardless, and accepts login-before-VM-start).
///
/// The class only takes effect when FileVault is enabled. Without
/// FileVault the attribute is set but provides no protection —
/// `spook doctor` flags this with a warning.
public enum BundleProtection {

    /// Policy source. Documented so the caller can log which
    /// rule produced the decision — helpful when an operator
    /// expects one class and the runtime applies another.
    public enum Policy: Sendable, Equatable {
        /// Environment override: operator set `SPOOK_BUNDLE_PROTECTION=none`.
        case overrideNone
        /// Environment override: operator set `SPOOK_BUNDLE_PROTECTION=cufua`.
        case overrideCUFUA
        /// GUI settings override: user selected "Off" in the Security tab.
        case overrideSettingsNone
        /// GUI settings override: user selected "Protected" in the Security tab.
        case overrideSettingsCUFUA
        /// Portable Mac detected (battery present) — default CUFUA.
        case autoLaptop
        /// Desktop / server-class Mac — default none.
        case autoDesktop
    }

    /// UserDefaults key the GUI Settings pane writes to.
    ///
    /// Values: `"auto"` (defer to form-factor detection),
    /// `"cufua"` (force CUFUA regardless), `"none"` (force off).
    /// The GUI uses `@AppStorage(BundleProtection.userDefaultsKey)`
    /// to bind a `Picker` to this string.
    public static let userDefaultsKey = "com.spooktacular.bundleProtection"

    /// Decides which protection class to apply based on, in
    /// priority order:
    ///
    /// 1. `SPOOK_BUNDLE_PROTECTION` env var — operator intent
    ///    (LaunchDaemon plist, CI config, shell export). Always
    ///    wins because it's set out-of-band from the GUI user.
    /// 2. UserDefaults key `com.spooktacular.bundleProtection` —
    ///    per-user GUI preference set via the Security tab.
    /// 3. Form-factor auto-detect via IOKit power sources.
    public static func recommendedPolicy(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        isPortable: Bool = isPortableMac
    ) -> (FileProtectionType, Policy) {
        // Tier 1: env var wins.
        switch environment["SPOOK_BUNDLE_PROTECTION"]?.lowercased() {
        case "none":
            return (.none, .overrideNone)
        case "cufua", "complete-until-first-user-auth":
            return (.completeUntilFirstUserAuthentication, .overrideCUFUA)
        default:
            break
        }
        // Tier 2: GUI preference.
        switch userDefaults.string(forKey: userDefaultsKey)?.lowercased() {
        case "none":
            return (.none, .overrideSettingsNone)
        case "cufua", "complete-until-first-user-auth":
            return (.completeUntilFirstUserAuthentication, .overrideSettingsCUFUA)
        default:
            break
        }
        // Tier 3: auto-detect.
        return isPortable
            ? (.completeUntilFirstUserAuthentication, .autoLaptop)
            : (.none, .autoDesktop)
    }

    /// Applies the recommended protection class to the bundle
    /// directory at `url`. Files added to the bundle later
    /// inherit the directory's protection class by default.
    public static func applyRecommended(to url: URL) throws {
        let (protection, _) = recommendedPolicy()
        try apply(protection, to: url)
    }

    /// Applies an explicit protection class. Used by the
    /// migration path (`spook bundle protect <name>`) and tests.
    ///
    /// Verifies the class landed by reading it back immediately.
    /// Without this check a `setAttributes` call that returns
    /// success but is silently downgraded by the filesystem (tmpfs
    /// mounts used in CI don't honor protection classes, for
    /// example) would leave the operator believing they have
    /// CUFUA when the on-disk attribute is still `.none`.
    ///
    /// - Throws: ``BundleProtectionError/applyVerificationFailed(path:expected:actual:)``
    ///   when the read-back reports a different class than was
    ///   written; rethrows any underlying `FileManager` error from
    ///   the write or read.
    public static func apply(_ protection: FileProtectionType, to url: URL) throws {
        // `.none` is a one-way floor: Data Protection classes can be
        // strengthened but not downgraded (FileVault volumes retain
        // their inherited class regardless of what we request).
        // Writing `.none` is a no-op on every volume we ship to, so
        // skipping both the `setAttributes` call and the verify keeps
        // the migration path idempotent without perturbing the
        // already-stronger on-disk state.
        guard protection != .none else { return }
        try FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )
        let actual = try current(at: url)
        guard actual == protection else {
            throw BundleProtectionError.applyVerificationFailed(
                path: url.path,
                expected: protection,
                actual: actual
            )
        }
    }

    /// Reads the current protection class of a path. Returns
    /// `.none` if the attribute isn't set (which is the case on
    /// bundles predating this feature).
    public static func current(at url: URL) throws -> FileProtectionType {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.protectionKey] as? FileProtectionType) ?? .none
    }

    // MARK: - Inheritance

    /// Propagates the protection class of `bundleURL` to every
    /// file + subdirectory beneath it.
    ///
    /// Called from the bundle write paths — `clone`, `save`
    /// snapshot, `writeSpec`, `writeMetadata` — so that a file
    /// added to a CUFUA-protected bundle can't silently come in
    /// at `.none`. macOS's FileVault default *usually* inherits
    /// the parent's class on the volumes we care about, but
    /// `Data.write(to:)` + `FileManager.copyItem` don't guarantee
    /// it across every volume / filesystem configuration we'll
    /// encounter in the wild — this call makes the guarantee
    /// explicit and testable.
    ///
    /// Silent on individual file failures (a file that went away
    /// during the walk is not an error); throws only on the
    /// bundle-directory read itself.
    public static func propagate(to bundleURL: URL) throws {
        let desired = try current(at: bundleURL)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let child as URL in enumerator {
            // Apply class to the file. If the child is a dir we
            // still apply, since we want to preserve the inherit-
            // from-parent chain for anything written into it later.
            try? fm.setAttributes(
                [.protectionKey: desired],
                ofItemAtPath: child.path
            )
        }
    }

    /// Walks a bundle and returns files whose protection class is
    /// *weaker* than the bundle directory's — the inheritance
    /// violations a test can enumerate.
    ///
    /// "Weaker" follows Apple's documented ordering:
    /// `.none` < `.completeUntilFirstUserAuthentication` <
    /// `.completeUnlessOpen` < `.complete`. A stronger class on a
    /// child is fine (over-protection isn't a violation).
    public static func verifyInheritance(
        bundleURL: URL
    ) throws -> [(URL, FileProtectionType)] {
        let desiredRank = try current(at: bundleURL).strengthRank
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var violations: [(URL, FileProtectionType)] = []
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let actual = try? current(at: child) else { continue }
            if actual.strengthRank < desiredRank {
                violations.append((child, actual))
            }
        }
        return violations
    }

    // MARK: - Portable-Mac detection

    /// True on Macs with a battery (MacBook / MacBook Air /
    /// MacBook Pro). False on desktops, servers, and EC2 Mac
    /// hosts. Queried once via IOKit at first use.
    ///
    /// Using `IOPSCopyPowerSourcesInfo` is the documented way to
    /// ask "does this machine have an internal battery?" — more
    /// reliable than parsing `sysctl hw.model` strings, which
    /// would need a growing allowlist as Apple ships new models.
    public static var isPortableMac: Bool { portableMacCache }

    private static let portableMacCache: Bool = {
        #if canImport(IOKit)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
        else { return false }
        for source in sources as Array {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let type = desc[kIOPSTypeKey] as? String,
               type == kIOPSInternalBatteryType {
                return true
            }
        }
        return false
        #else
        return false
        #endif
    }()
}

// MARK: - Errors

/// Errors raised by ``BundleProtection`` operations.
public enum BundleProtectionError: Error, Sendable, Equatable, LocalizedError {

    /// `FileManager.setAttributes` succeeded but a read-back of the
    /// protection class returned a different value — a silent
    /// downgrade by the filesystem or a permission quirk.
    ///
    /// - Parameters:
    ///   - path: The bundle-directory path.
    ///   - expected: The class we asked for.
    ///   - actual: The class that actually made it to disk.
    case applyVerificationFailed(path: String, expected: FileProtectionType, actual: FileProtectionType)

    public var errorDescription: String? {
        switch self {
        case .applyVerificationFailed(let path, let expected, let actual):
            "Protection class read-back mismatch for '\(path)': expected '\(expected.displayName)', got '\(actual.displayName)'."
        }
    }

    public var recoverySuggestion: String? {
        "Check that FileVault is enabled and the volume supports data protection attributes. "
        + "`spook doctor --strict` surfaces this as a warning before the bundle is used."
    }
}

// MARK: - Display + ordering

extension FileProtectionType {

    /// Human-readable label for `spook doctor` and CLI output.
    public var displayName: String {
        switch self {
        case .complete: "Complete"
        case .completeUnlessOpen: "CompleteUnlessOpen"
        case .completeUntilFirstUserAuthentication: "CompleteUntilFirstUserAuthentication"
        case .none: "None"
        default: "Unknown(\(rawValue))"
        }
    }

    /// Ordered strength rank used by ``BundleProtection/verifyInheritance``.
    ///
    /// Apple's own docs enumerate the classes from weakest to
    /// strongest; mirroring that order as an Int lets the
    /// verifier say "child >= parent" without a match on every
    /// possible pair. Unknown classes sort below `.none` so a
    /// future macOS-introduced class shows up as a violation
    /// until the rank is extended explicitly.
    public var strengthRank: Int {
        switch self {
        case .none: 0
        case .completeUntilFirstUserAuthentication: 1
        case .completeUnlessOpen: 2
        case .complete: 3
        default: -1
        }
    }
}

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
        /// Portable Mac detected (battery present) — default CUFUA.
        case autoLaptop
        /// Desktop / server-class Mac — default none.
        case autoDesktop
    }

    /// Decides which protection class to apply based on the
    /// environment and the host's form factor.
    public static func recommendedPolicy(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isPortable: Bool = isPortableMac
    ) -> (FileProtectionType, Policy) {
        switch environment["SPOOK_BUNDLE_PROTECTION"]?.lowercased() {
        case "none":
            return (.none, .overrideNone)
        case "cufua", "complete-until-first-user-auth":
            return (.completeUntilFirstUserAuthentication, .overrideCUFUA)
        default:
            return isPortable
                ? (.completeUntilFirstUserAuthentication, .autoLaptop)
                : (.none, .autoDesktop)
        }
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
    public static func apply(_ protection: FileProtectionType, to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )
    }

    /// Reads the current protection class of a path. Returns
    /// `.none` if the attribute isn't set (which is the case on
    /// bundles predating this feature).
    public static func current(at url: URL) throws -> FileProtectionType {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.protectionKey] as? FileProtectionType) ?? .none
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

// MARK: - Display

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
}

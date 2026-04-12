import Foundation

/// Checks version compatibility between the host macOS
/// and a macOS restore image (IPSW).
///
/// macOS virtual machines require the guest OS version to be
/// equal to or older than the host OS version. This module
/// provides a single check used by all interfaces — CLI, GUI,
/// API, and the Kubernetes operator — to ensure consistent
/// behavior.
///
/// ## Usage
///
/// ```swift
/// let image = try await VZMacOSRestoreImage.latestSupported
/// let result = Compatibility.check(imageVersion: image.operatingSystemVersion)
///
/// if !result.isCompatible {
///     print(result.errorMessage!)
/// }
/// ```
///
/// ## Consistency Guarantee
///
/// All interfaces call ``check(hostVersion:imageVersion:)``
/// before downloading or installing an IPSW. This ensures
/// the user gets the same error message and guidance
/// regardless of whether they use the CLI, the GUI, or
/// `kubectl apply`.
public enum Compatibility {

    /// The result of a compatibility check.
    public enum Result: Sendable, Equatable {

        /// The image is compatible with the host.
        case compatible

        /// The host macOS is too old to install this image.
        ///
        /// - Parameters:
        ///   - hostVersion: The macOS version running on the host.
        ///   - imageVersion: The macOS version in the IPSW.
        case hostTooOld(
            hostVersion: OperatingSystemVersion,
            imageVersion: OperatingSystemVersion
        )

        /// Whether the image can be installed on this host.
        public var isCompatible: Bool {
            switch self {
            case .compatible: true
            case .hostTooOld: false
            }
        }

        /// A human-readable error message, or `nil` if compatible.
        ///
        /// The message includes both versions and actionable
        /// guidance. The same message is shown by the CLI, GUI,
        /// API, and Kubernetes operator.
        public var errorMessage: String? {
            switch self {
            case .compatible:
                return nil

            case .hostTooOld(let host, let image):
                let hostStr = versionString(host)
                let imageStr = versionString(image)
                return """
                    Your macOS (\(hostStr)) cannot install macOS \(imageStr). \
                    The guest version must be ≤ the host version. \
                    Update your Mac to macOS \(imageStr) or newer, \
                    or use a pre-built OCI image: \
                    spook create <name> --pull ghcr.io/spooktacular/macos:<version>
                    """
            }
        }
    }

    /// The macOS version running on this host.
    public static var hostVersion: OperatingSystemVersion {
        ProcessInfo.processInfo.operatingSystemVersion
    }

    /// Checks whether an IPSW image version is compatible
    /// with the host macOS version.
    ///
    /// The rule is simple: `image ≤ host` by
    /// (major, minor, patch) tuple comparison.
    ///
    /// - Parameters:
    ///   - hostVersion: The host macOS version. Defaults to
    ///     the current system version.
    ///   - imageVersion: The macOS version in the IPSW.
    /// - Returns: ``Result/compatible`` or
    ///   ``Result/hostTooOld(hostVersion:imageVersion:)``.
    public static func check(
        hostVersion: OperatingSystemVersion? = nil,
        imageVersion: OperatingSystemVersion
    ) -> Result {
        let host = hostVersion ?? self.hostVersion

        return compare(host, isAtLeast: imageVersion)
            ? .compatible
            : .hostTooOld(hostVersion: host, imageVersion: imageVersion)
    }

    // MARK: - Private

    /// Tuple comparison: `lhs >= rhs` by (major, minor, patch).
    private static func compare(
        _ lhs: OperatingSystemVersion,
        isAtLeast rhs: OperatingSystemVersion
    ) -> Bool {
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion > rhs.majorVersion
        }
        if lhs.minorVersion != rhs.minorVersion {
            return lhs.minorVersion > rhs.minorVersion
        }
        return lhs.patchVersion >= rhs.patchVersion
    }

    /// Formats a version as "major.minor.patch".
    private static func versionString(
        _ v: OperatingSystemVersion
    ) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

// MARK: - OperatingSystemVersion + Equatable

/// `OperatingSystemVersion` doesn't conform to `Equatable` by
/// default. We add it so ``Compatibility/Result`` can be
/// `Equatable` for testing.
extension OperatingSystemVersion: @retroactive Equatable {
    public static func == (
        lhs: OperatingSystemVersion,
        rhs: OperatingSystemVersion
    ) -> Bool {
        lhs.majorVersion == rhs.majorVersion
        && lhs.minorVersion == rhs.minorVersion
        && lhs.patchVersion == rhs.patchVersion
    }
}

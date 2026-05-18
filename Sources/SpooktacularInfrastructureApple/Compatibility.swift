import Foundation
import SpooktacularCore
import SpooktacularApplication
import os

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
    public enum Result: Sendable {

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
                return "Your macOS (\(hostStr)) cannot install macOS \(imageStr). "
                    + "The guest version must be \u{2264} the host version. "
                    + "Update your Mac to macOS \(imageStr) or newer."
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

        Log.compatibility.info("Checking compatibility: host \(host.majorVersion, privacy: .public).\(host.minorVersion, privacy: .public).\(host.patchVersion, privacy: .public) vs image \(imageVersion.majorVersion, privacy: .public).\(imageVersion.minorVersion, privacy: .public).\(imageVersion.patchVersion, privacy: .public)")

        guard compare(host, isAtLeast: imageVersion) else {
            Log.compatibility.error("Compatibility check failed: host too old")
            return .hostTooOld(hostVersion: host, imageVersion: imageVersion)
        }

        Log.compatibility.debug("Compatibility check passed")
        return .compatible
    }

    private static func compare(
        _ lhs: OperatingSystemVersion,
        isAtLeast rhs: OperatingSystemVersion
    ) -> Bool {
        (lhs.majorVersion, lhs.minorVersion, lhs.patchVersion)
            >= (rhs.majorVersion, rhs.minorVersion, rhs.patchVersion)
    }

    private static func versionString(
        _ version: OperatingSystemVersion
    ) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

// MARK: - Equatable

extension Compatibility.Result: Equatable {
    public static func == (lhs: Compatibility.Result, rhs: Compatibility.Result) -> Bool {
        switch (lhs, rhs) {
        case (.compatible, .compatible):
            return true
        case (.hostTooOld(let lhsHost, let lhsImage), .hostTooOld(let rhsHost, let rhsImage)):
            return versionTuple(lhsHost) == versionTuple(rhsHost)
                && versionTuple(lhsImage) == versionTuple(rhsImage)
        default:
            return false
        }
    }

    private static func versionTuple(
        _ v: OperatingSystemVersion
    ) -> (Int, Int, Int) {
        (v.majorVersion, v.minorVersion, v.patchVersion)
    }
}

import Foundation
import NetworkExtension
import SystemExtensions
import os

/// Drives the install / replace / uninstall lifecycle of the
/// Spooktacular Network Filter `.systemextension` bundle
/// embedded in the main app under
/// `Contents/Library/SystemExtensions/`.
///
/// ## Why this class exists
///
/// `NEFilterManager.saveToPreferences()` writes the filter
/// configuration, but it does **not** install the extension
/// itself. Users must explicitly approve the extension in
/// System Settings → Privacy & Security the first time (and
/// re-approve after an OS upgrade that invalidates the signed
/// inventory). The one Apple-sanctioned path to trigger that
/// flow is
/// [`OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)`](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequest/2893420-activationrequest),
/// submitted via
/// [`OSSystemExtensionManager.shared`](https://developer.apple.com/documentation/systemextensions/ossystemextensionmanager).
///
/// The submitting process MUST be a GUI app bundle with the
/// matching team identifier — pure CLI tools can't invoke
/// this API reliably because the approval prompt is rendered
/// by `systemextensionsctl`'s GUI agent. So the activator
/// lives in code that the main `.app` drives; the CLI
/// `spooktacular egress apply` path merely writes
/// `NEFilterManager` config and asks the user to run the
/// GUI installer when saving fails with `.missingEntitlement`.
///
/// ## Apple references
///
/// - [System Extensions overview](https://developer.apple.com/documentation/systemextensions)
/// - [`OSSystemExtensionManager`](https://developer.apple.com/documentation/systemextensions/ossystemextensionmanager)
/// - [`OSSystemExtensionRequestDelegate`](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequestdelegate)
///
/// ## Delegate choices we make
///
/// The delegate protocol has four callbacks; our answers are:
///
/// | Callback | What we do | Why |
/// |---|---|---|
/// | `request(_:actionForReplacingExtension:withExtension:)` | `.replace` | Newer build from the main app bundle should always replace an older one. Falling back to `.cancel` strands users on stale filter code after every release. |
/// | `requestNeedsUserApproval(_:)` | Emit `.needsUserApproval` event | GUI shows a banner telling the user to visit System Settings → Privacy & Security. |
/// | `request(_:didFinishWithResult:)` | Emit `.installed` / `.willCompleteAfterReboot` | Success path. Reboot-required outcome is rare but possible after major OS updates. |
/// | `request(_:didFailWithError:)` | Emit `.failed(Error)` | Surfaces the specific `OSSystemExtensionError` code for diagnostics. |
///
/// The class is an `NSObject`-backed delegate because
/// `OSSystemExtensionRequestDelegate` is Obj-C protocol with
/// `NSObject` base; Swift-only classes can't adopt it.
public final class SystemExtensionActivator: NSObject,
                                              OSSystemExtensionRequestDelegate,
                                              @unchecked Sendable {

    /// Bundle identifier of the `.systemextension` we manage.
    /// Must match
    /// `NEFilterConfigurator.extensionBundleIdentifier` and
    /// the `CFBundleIdentifier` of `SpooktacularNetworkFilter-Info.plist`.
    public static let extensionIdentifier = NEFilterConfigurator.extensionBundleIdentifier

    /// Events emitted on the `AsyncStream` returned by ``activate()``.
    public enum Event: Sendable {
        /// User must approve in System Settings → Privacy &
        /// Security. The GUI usually surfaces this as an alert
        /// with a "Open System Settings" button.
        case needsUserApproval
        /// Extension is installed and enabled. Safe to call
        /// `NEFilterConfigurator.applyPolicies` after this.
        case installed
        /// Activation succeeded but requires a reboot (rare —
        /// happens right after a macOS major upgrade that
        /// invalidated the cached extension inventory).
        case willCompleteAfterReboot
        /// Activation failed. The wrapped error is usually
        /// `OSSystemExtensionError`; inspect `.code` for the
        /// specific reason.
        case failed(Error)
    }

    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "system-extension-activator"
    )

    /// Stream continuation for the active submission. Set on
    /// `submitRequest`, cleared on terminal event. Only one
    /// submission can be in flight at a time — concurrent
    /// submissions would race the delegate callbacks, and
    /// `OSSystemExtensionManager` serializes on its end anyway.
    private var continuation: AsyncStream<Event>.Continuation?

    public override init() { super.init() }

    /// Submits an activation request for the embedded
    /// Network Filter extension. Yields status events until
    /// the request reaches a terminal state
    /// (`installed` / `willCompleteAfterReboot` / `failed`).
    ///
    /// Caller is expected to iterate the stream on a `Task`
    /// and update UI accordingly. Typical pattern:
    ///
    /// ```swift
    /// let activator = SystemExtensionActivator()
    /// for await event in activator.activate() {
    ///     switch event {
    ///     case .needsUserApproval: banner = .openSettings
    ///     case .installed: banner = .success
    ///     case .willCompleteAfterReboot: banner = .pleaseReboot
    ///     case .failed(let error): banner = .error(error)
    ///     }
    /// }
    /// ```
    public func activate() -> AsyncStream<Event> {
        AsyncStream { continuation in
            self.continuation = continuation
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: Self.extensionIdentifier,
                queue: .main
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
            Self.log.notice(
                "Submitted activation request for \(Self.extensionIdentifier, privacy: .public)"
            )
        }
    }

    /// Submits a deactivation request. Symmetric to
    /// ``activate()``. Typically only used by uninstallation
    /// flows / QA scripts — normal operation leaves the
    /// extension installed indefinitely.
    public func deactivate() -> AsyncStream<Event> {
        AsyncStream { continuation in
            self.continuation = continuation
            let request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: Self.extensionIdentifier,
                queue: .main
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
            Self.log.notice(
                "Submitted deactivation request for \(Self.extensionIdentifier, privacy: .public)"
            )
        }
    }

    // MARK: - OSSystemExtensionRequestDelegate

    public func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension new: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always replace. The main app bundle carries the
        // version we want running; staying on an older build
        // strands users on stale filter code after upgrades.
        Self.log.notice(
            "Replacing extension \(existing.bundleVersion, privacy: .public) with \(new.bundleVersion, privacy: .public)"
        )
        return .replace
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Self.log.notice(
            "Extension \(request.identifier, privacy: .public) needs user approval in System Settings"
        )
        continuation?.yield(.needsUserApproval)
    }

    public func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            Self.log.notice("Extension \(request.identifier, privacy: .public) installed")
            continuation?.yield(.installed)
        case .willCompleteAfterReboot:
            Self.log.notice(
                "Extension \(request.identifier, privacy: .public) will finish after reboot"
            )
            continuation?.yield(.willCompleteAfterReboot)
        @unknown default:
            Self.log.error(
                "Unknown OSSystemExtensionRequest.Result — treating as installed"
            )
            continuation?.yield(.installed)
        }
        continuation?.finish()
        continuation = nil
    }

    public func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        Self.log.error(
            "Extension request failed: \(error.localizedDescription, privacy: .public)"
        )
        continuation?.yield(.failed(error))
        continuation?.finish()
        continuation = nil
    }
}

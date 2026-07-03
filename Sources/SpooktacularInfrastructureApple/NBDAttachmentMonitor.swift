import Foundation
import os
@preconcurrency import Virtualization

/// Delegate for `VZNetworkBlockDeviceStorageDeviceAttachment`
/// that funnels connect / reconnect / unrecoverable-error
/// callbacks into `os_log` and an optional Swift async
/// `AsyncStream` so GUI code can surface banner notifications
/// when an NBD-backed disk loses its backend.
///
/// ## Why separate from `VirtualMachine`
///
/// `VZNetworkBlockDeviceStorageDeviceAttachment` holds a
/// weak reference to its delegate. If we made the VM itself
/// the delegate, the delegate pointer would risk being nil
/// just when a reconnect callback fires (e.g., during a
/// stop/start dance). A long-lived monitor tied to the
/// attachment's lifetime is simpler.
///
/// ## Apple APIs
///
/// - [`VZNetworkBlockDeviceStorageDeviceAttachmentDelegate`](https://developer.apple.com/documentation/virtualization/vznetworkblockdevicestoragedeviceattachmentdelegate)
///   — two optional callbacks:
///   `attachmentWasConnected:` and
///   `attachment:didEncounterError:`.
public final class NBDAttachmentMonitor: NSObject, VZNetworkBlockDeviceStorageDeviceAttachmentDelegate {

    private let log: Logger
    private let onEvent: (@Sendable (Event) -> Void)?

    /// Lifecycle signals clients can observe.
    public enum Event: Sendable, Equatable {
        /// First connection succeeded or a reconnect
        /// succeeded after a recoverable failure.
        case connected(url: URL)
        /// Unrecoverable — Apple's framework docs: *"The NBD
        /// client will be in a non-functional state after
        /// this method is invoked."* The attached disk will
        /// stop serving reads/writes; the guest sees I/O
        /// errors until the VM restarts.
        case unrecoverableError(url: URL, description: String)
    }

    /// URL of the server this monitor is watching. Stored
    /// separately so the callback can surface it without
    /// dereferencing the (weak) attachment.
    private let url: URL

    public init(
        url: URL,
        category: String = "nbd",
        onEvent: (@Sendable (Event) -> Void)? = nil
    ) {
        self.url = url
        self.log = Logger(subsystem: "com.spooktacular.app", category: category)
        self.onEvent = onEvent
        super.init()
    }

    // MARK: - VZNetworkBlockDeviceStorageDeviceAttachmentDelegate

    public func attachmentWasConnected(
        _ attachment: VZNetworkBlockDeviceStorageDeviceAttachment
    ) {
        log.notice("NBD attachment connected: \(attachment.url.absoluteString, privacy: .public)")
        onEvent?(.connected(url: attachment.url))
    }

    public func attachment(
        _ attachment: VZNetworkBlockDeviceStorageDeviceAttachment,
        didEncounterError error: any Error
    ) {
        log.error(
            "NBD attachment FAILED: \(attachment.url.absoluteString, privacy: .public) — \(error.localizedDescription, privacy: .public)"
        )
        onEvent?(.unrecoverableError(
            url: attachment.url,
            description: error.localizedDescription
        ))
    }
}

import Foundation

/// Disk synchronization mode for both local and NBD-backed
/// storage attachments. Matches Apple's
/// `VZDiskSynchronizationMode` 1:1.
///
/// The header:
/// `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Virtualization.framework/Versions/A/Headers/VZDiskSynchronizationMode.h`
///
/// See
/// [`VZDiskSynchronizationMode`](https://developer.apple.com/documentation/virtualization/vzdisksynchronizationmode).
public enum DiskSyncMode: String, Sendable, Codable, Equatable, Hashable, CaseIterable {

    /// `VZDiskSynchronizationModeFull`. Guest `flush` /
    /// `barrier` commands are forwarded to the underlying
    /// storage. Crash-safe — use this unless you have a
    /// very specific ephemeral-task use case.
    case full

    /// `VZDiskSynchronizationModeNone`. Ignores guest flush
    /// commands. Higher throughput but corrupts data on any
    /// crash, host reboot, or NBD disconnect. Only correct
    /// for ephemeral one-shot workloads (CI runners that
    /// discard on failure).
    case none
}

/// A disk backed by a remote Network Block Device (NBD)
/// server, attached to the VM via Apple's
/// `VZNetworkBlockDeviceStorageDeviceAttachment` (macOS 14+).
///
/// ## Use cases
///
/// - **Fleet-shared golden images.** One NBD server exposes a
///   read-only base image; every VM in a runner pool mounts
///   it. Writes are caught by a copy-on-write overlay the
///   server manages.
/// - **AWS EBS volumes** (Track M). The EBS NBD bridge
///   translates NBD reads/writes into `ebs:GetSnapshotBlock` /
///   `ebs:PutSnapshotBlock` calls using federated STS creds.
/// - **Custom block storage.** An operator can write any
///   NBD-speaking daemon — FUSE-style, object-store-backed,
///   even a simulated-error disk for chaos testing — and the
///   VM consumes it as a plain block device.
///
/// ## Apple APIs
///
/// - [`VZNetworkBlockDeviceStorageDeviceAttachment`](https://developer.apple.com/documentation/virtualization/vznetworkblockdevicestoragedeviceattachment)
///   (macOS 14.0+) — the attachment.
/// - [`VZNetworkBlockDeviceStorageDeviceAttachmentDelegate`](https://developer.apple.com/documentation/virtualization/vznetworkblockdevicestoragedeviceattachmentdelegate)
///   — reports connect / reconnect / unrecoverable-error events.
///
/// ## Entitlement
///
/// Per Apple's header: *"Using this attachment requires the
/// app to have the `com.apple.security.network.client`
/// entitlement as this attachment opens an outgoing network
/// connection."* Spooktacular's entitlements plist already
/// carries this (needed for HTTP API + webhook audit sinks).
public struct NBDBackedDisk: Sendable, Codable, Equatable, Hashable {

    /// NBD URI per
    /// <https://github.com/NetworkBlockDevice/nbd/blob/master/doc/uri.md>.
    /// Supported forms:
    ///
    /// - `nbd://host:port/export` — TCP to `host:port`,
    ///   selecting the `export` name during negotiation.
    /// - `nbd+unix:///export?socket=/path/to.sock` — Unix-
    ///   domain-socket variant (useful for localhost
    ///   bridges like the EBS adapter).
    public let url: URL

    /// Timeout in seconds for the client↔server
    /// connection. When the timeout expires the client
    /// attempts a reconnect. `0` means "use the framework
    /// default" (~5 s at the time of writing; Apple
    /// documents this as `VZNetworkBlockDeviceStorageDeviceAttachment(URL:error:)`
    /// "optimized default values").
    public let timeoutSeconds: TimeInterval

    /// When `true`, the guest sees the disk as read-only
    /// regardless of what the NBD server advertises during
    /// handshake. Use this for "reference volumes" the user
    /// must not mutate, even if the server would allow it.
    public let forcedReadOnly: Bool

    /// Crash-safety mode. Default `.full` unless the disk is
    /// genuinely ephemeral.
    public let syncMode: DiskSyncMode

    /// Which controller hosts the disk — matches the bus
    /// options for local-image ``AdditionalDisk``.
    /// `.usb` is rejected at config time: USB mass storage
    /// doesn't mix with NBD attachments in the framework
    /// (the XHCI controller accepts `VZUSBMassStorageDeviceConfiguration`
    /// whose attachment must be a local-image subclass, not
    /// `VZNetworkBlockDeviceStorageDeviceAttachment`).
    public let bus: SecondaryDiskBus

    public init(
        url: URL,
        timeoutSeconds: TimeInterval = 0,
        forcedReadOnly: Bool = false,
        syncMode: DiskSyncMode = .full,
        bus: SecondaryDiskBus = .virtio
    ) {
        self.url = url
        self.timeoutSeconds = timeoutSeconds
        self.forcedReadOnly = forcedReadOnly
        self.syncMode = syncMode
        self.bus = bus
    }
}

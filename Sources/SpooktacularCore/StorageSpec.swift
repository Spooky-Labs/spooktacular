import Foundation

/// Storage controller type exposed to the guest.
///
/// Apple's Virtualization framework ships two first-class
/// controllers:
///
/// - **`VZVirtioBlockDeviceConfiguration`** — the paravirtualised
///   virtio-blk path. Universally compatible across macOS 11+
///   hosts and every mainstream guest OS (macOS, Linux). Pays
///   a ~5 % per-request overhead vs. the native-kernel path.
///   Default; good balance of compatibility and performance.
///
/// - **`VZNVMeExpressControllerDeviceConfiguration`** — NVMe
///   controller emulation, macOS 12+ on the host. Apple's
///   WWDC23 "Create seamless experiences with Virtualization"
///   (session 10007) reports **15–30 % higher sequential I/O**
///   than virtio-blk on identical images. Linux guests since
///   5.0 ship the nvme driver natively; macOS guests do NOT
///   benefit (the macOS NVMe stack is tuned for physical
///   devices with slightly different queue semantics).
///
/// Docs:
/// - [`VZVirtioBlockDeviceConfiguration`](https://developer.apple.com/documentation/virtualization/vzvirtioblockdeviceconfiguration)
/// - [`VZNVMeExpressControllerDeviceConfiguration`](https://developer.apple.com/documentation/virtualization/vznvmeexpresscontrollerdeviceconfiguration)
public enum StorageController: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    /// Virtio block device — paravirtualised, universal.
    case virtio
    /// NVMe controller — macOS 12+ host, Linux 5.0+ guest.
    case nvme

    /// Human-legible display name for the GUI picker.
    public var displayName: String {
        switch self {
        case .virtio: return "Virtio Block"
        case .nvme: return "NVMe"
        }
    }
}

/// How a secondary disk is presented to the guest.
///
/// Apple's Virtualization framework lets the same underlying
/// ``VZDiskImageStorageDeviceAttachment`` be plumbed through
/// any of three controllers — each with distinct guest-OS
/// driver semantics, hot-plug story, and performance
/// envelope. `SecondaryDiskBus` picks the controller per-disk
/// so an operator can mix a fast NVMe scratch volume with a
/// "removable" USB installer in one VM.
public enum SecondaryDiskBus: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    /// Virtio-blk — paravirtualised, universally compatible.
    /// Same bus as the primary disk. Cannot hot-plug.
    case virtio
    /// NVM Express. Linux guests only (per Apple's
    /// `VZNVMExpressControllerDeviceConfiguration` header).
    case nvme
    /// USB mass storage via `VZXHCIControllerConfiguration` +
    /// `VZUSBMassStorageDeviceConfiguration`. Hot-pluggable
    /// at runtime with
    /// [`VZUSBController.attach(device:completionHandler:)`](https://developer.apple.com/documentation/virtualization/vzusbcontroller/attach(device:completionhandler:))
    /// — the only bus that supports runtime insertion /
    /// removal. Works on both macOS 13+ and Linux guests.
    case usb

    public var displayName: String {
        switch self {
        case .virtio: return "Virtio Block"
        case .nvme:   return "NVMe"
        case .usb:    return "USB Mass Storage"
        }
    }
}

/// A secondary disk image attached to the VM beyond the
/// primary bundle disk.
///
/// Use cases: scratch storage for CI jobs that's discardable
/// without re-creating the primary disk; a read-only reference
/// image (distro ISO, training dataset) mounted alongside the
/// boot disk; multi-disk topologies for database performance
/// testing.
///
/// Each entry maps to a separate
/// `VZVirtioBlockDeviceConfiguration` (or NVMe per
/// ``VirtualMachineSpecification/storageController``) backed by
/// `VZDiskImageStorageDeviceAttachment(url:readOnly:)` on the
/// Virtualization.framework side. See
/// [`VZDiskImageStorageDeviceAttachment`](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment).
public struct AdditionalDisk: Sendable, Codable, Equatable, Hashable {

    /// Absolute host path to the disk image file.
    ///
    /// Stored as a string rather than a `URL` so JSON round-
    /// trip is tidy (matches `SharedFolder.hostPath`'s shape).
    public let hostPath: String

    /// Whether the guest sees this as a read-only disk.
    ///
    /// Maps to
    /// [`VZDiskImageStorageDeviceAttachment.init(url:readOnly:)`](https://developer.apple.com/documentation/virtualization/vzdiskimagestorageattachment/init(url:readonly:))'s
    /// `readOnly` parameter. A read-only attach still boots
    /// most guests but writes fail visibly — useful for
    /// reference volumes.
    public let readOnly: Bool

    /// Which controller this disk lives behind. Defaults to
    /// ``SecondaryDiskBus/virtio`` to match the primary bus
    /// if not set.
    public let bus: SecondaryDiskBus

    public init(hostPath: String, readOnly: Bool = false, bus: SecondaryDiskBus = .virtio) {
        self.hostPath = hostPath
        self.readOnly = readOnly
        self.bus = bus
    }

    /// Custom `init(from:)` with `decodeIfPresent` on `bus`
    /// so pre-Track-G bundles that didn't carry the field
    /// still load with the sensible virtio default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hostPath = try container.decode(String.self, forKey: .hostPath)
        self.readOnly = try container.decode(Bool.self, forKey: .readOnly)
        self.bus = try container.decodeIfPresent(SecondaryDiskBus.self, forKey: .bus) ?? .virtio
    }

    private enum CodingKeys: String, CodingKey {
        case hostPath, readOnly, bus
    }
}

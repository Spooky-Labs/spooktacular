import Foundation

/// A directory shared between the host and the virtual machine.
///
/// Each `SharedFolder` maps a host directory to a mount point
/// inside the guest via the VirtIO file-system device. The first
/// shared folder in a ``VirtualMachineSpecification`` uses the macOS guest automount
/// tag so it appears automatically in the guest's Finder sidebar.
///
/// ## Example
///
/// ```swift
/// let folder = SharedFolder(
///     hostPath: "/Users/me/Projects",
///     tag: "projects",
///     readOnly: true
/// )
/// ```
public struct SharedFolder: Sendable, Codable, Equatable, Hashable {

    /// The absolute path to the directory on the host.
    public let hostPath: String

    /// The mount tag used to identify this share inside the guest.
    ///
    /// For the first folder in a spec's ``VirtualMachineSpecification/sharedFolders``
    /// array, this value is overridden at configuration time with
    /// the macOS guest automount tag so the share appears
    /// automatically in Finder.
    public let tag: String

    /// Whether the guest has read-only access to the shared directory.
    ///
    /// Defaults to `false`, granting the guest full read-write access.
    public let readOnly: Bool

    /// Creates a new shared folder specification.
    ///
    /// - Parameters:
    ///   - hostPath: Absolute path to the directory on the host.
    ///   - tag: Mount tag for guest-side identification.
    ///   - readOnly: Whether the guest has read-only access.
    ///     Defaults to `false`.
    public init(hostPath: String, tag: String, readOnly: Bool = false) {
        self.hostPath = hostPath
        self.tag = tag
        self.readOnly = readOnly
    }
}

/// The hardware specification for a virtual machine.
///
/// A `VirtualMachineSpecification` defines the CPU, memory, disk, display, network,
/// audio, and sharing configuration for a macOS virtual machine.
/// These values are persisted as `config.json` inside the VM
/// bundle directory.
///
/// ## Minimum Requirements
///
/// macOS virtual machines on Apple Silicon require a minimum of
/// 4 CPU cores to boot reliably. The initializer enforces this
/// floor automatically — requesting fewer than 4 cores results
/// in a spec with exactly 4.
///
/// ```swift
/// let spec = VirtualMachineSpecification(cpuCount: 2)
/// print(spec.cpuCount) // 4
/// ```
///
/// ## Example
///
/// ```swift
/// let spec = VirtualMachineSpecification(
///     cpuCount: 8,
///     memorySizeInBytes: 16 * 1024 * 1024 * 1024,
///     diskSizeInBytes: 100 * 1024 * 1024 * 1024,
///     displayCount: 2,
///     networkMode: .nat,
///     audioEnabled: true,
///     sharedFolders: [
///         SharedFolder(hostPath: "/Users/me/shared", tag: "shared")
///     ]
/// )
/// ```
public struct VirtualMachineSpecification: Sendable, Codable, Equatable, Hashable {

    /// The minimum number of CPU cores required for a macOS VM
    /// to boot without freezing.
    ///
    /// This value was determined empirically — Apple's
    /// `VZMacOSConfigurationRequirements.minimumSupportedCPUCount`
    /// may report a lower number, but VMs with fewer than 4 cores
    /// hang during boot on some configurations.
    public static let minimumCPUCount = 4

    /// The number of virtual CPU cores allocated to the VM.
    ///
    /// Always at least ``minimumCPUCount``. Values below the
    /// minimum are silently raised.
    public let cpuCount: Int

    /// The amount of RAM allocated to the VM, in bytes.
    ///
    /// Defaults to 8 GiB. Must be at least the value reported by
    /// `VZMacOSConfigurationRequirements.minimumSupportedMemorySize`
    /// for the installed macOS version.
    public let memorySizeInBytes: UInt64

    /// The size of the primary disk image, in bytes.
    ///
    /// Defaults to 64 GiB. The disk image is created as an APFS
    /// sparse file — it only consumes host disk space as the
    /// guest writes data.
    public let diskSizeInBytes: UInt64

    /// The number of virtual displays attached to the VM.
    ///
    /// Valid range is 1–2. Each display is backed by a
    /// `VZMacGraphicsDisplayConfiguration` at 1920×1200 @ 80 PPI.
    public let displayCount: Int

    /// The network configuration mode.
    ///
    /// See ``NetworkMode`` for the available options and their
    /// implications.
    public let networkMode: NetworkMode

    /// Whether the VM has an audio output device attached.
    ///
    /// When `true`, a `VZVirtioSoundDeviceConfiguration` with an
    /// output stream is added to the VM configuration. Defaults
    /// to `true`.
    public let audioEnabled: Bool

    /// Whether the VM has a microphone input device attached.
    ///
    /// Only effective when ``audioEnabled`` is `true`. When both
    /// are `true`, an input stream is added to the sound device
    /// alongside the output stream. Defaults to `false`.
    public let microphoneEnabled: Bool

    /// The directories shared between host and guest.
    ///
    /// Each entry becomes a `VZVirtioFileSystemDeviceConfiguration`
    /// in the VM configuration. The first folder uses the macOS
    /// guest automount tag for automatic Finder visibility.
    /// Defaults to an empty array (no shared folders).
    public let sharedFolders: [SharedFolder]

    /// An explicit MAC address for the VM's primary network device.
    ///
    /// When `nil`, the Virtualization framework generates a random
    /// MAC address. Set this to a valid ``MACAddress`` when you need
    /// a stable network identity across reboots. Defaults to `nil`.
    public let macAddress: MACAddress?

    /// Whether the guest display automatically resizes to match
    /// the host window.
    ///
    /// Defaults to `true`. This hint is consumed by the display
    /// layer — the Virtualization framework itself always creates
    /// fixed-resolution displays.
    public let autoResizeDisplay: Bool

    /// Storage controller type used for the primary and any
    /// additional disks.
    ///
    /// Defaults to ``StorageController/virtio`` which works on
    /// every guest OS the framework supports. Set to
    /// ``StorageController/nvme`` on macOS 12+ hosts with
    /// guests that ship an NVMe driver (every Linux kernel
    /// since 5.0; macOS guests do not benefit — use virtio).
    /// NVMe typically yields 15–30 % higher sequential I/O
    /// than virtio-blk on the same image per Apple's WWDC23
    /// benchmarks.
    ///
    /// Maps to either `VZVirtioBlockDeviceConfiguration` or
    /// `VZNVMeExpressControllerDeviceConfiguration` on the
    /// Virtualization.framework side.
    public let storageController: StorageController

    /// Secondary disk images attached beyond the primary
    /// bundle disk. Each is a separate
    /// `VZVirtioBlockDeviceConfiguration` (or NVMe per
    /// ``storageController``) backed by a host file.
    ///
    /// Canonical use case: a scratch volume for CI output
    /// that survives the primary disk being reset/reverted.
    /// Defaults to an empty list.
    public let additionalDisks: [AdditionalDisk]

    /// Disks backed by remote NBD servers. Each attaches as
    /// a `VZNetworkBlockDeviceStorageDeviceAttachment`
    /// wrapped in a virtio-blk or NVMe device per its
    /// `bus`. Requires macOS 14+ on the host (always true
    /// for us on macOS 26) and the
    /// `com.apple.security.network.client` entitlement.
    ///
    /// Track K primitive; Track M (EBS) builds on this by
    /// running a local NBD adapter that translates to the
    /// AWS EBS Direct API.
    public let networkBlockDevices: [NBDBackedDisk]

    /// The guest operating system this VM targets.
    ///
    /// Added in Track H. Defaults to ``GuestOS/macOS`` for
    /// back-compat with pre-Track-H bundles whose
    /// `config.json` doesn't carry this field — the
    /// `decodeIfPresent` path in `init(from:)` substitutes
    /// `.macOS` so existing Mac VMs keep booting unchanged.
    ///
    /// The infrastructure layer branches on this value to
    /// choose between the Mac-specific device graph
    /// (`VZMacOSBootLoader`, Mac keyboard/trackpad, Mac
    /// graphics) and the Linux-specific device graph
    /// (`VZEFIBootLoader`, USB keyboard/mouse, virtio
    /// graphics, XHCI USB controller).
    public let guestOS: GuestOS

    /// Whether the host and guest share a common clipboard.
    ///
    /// This field is retained for forward compatibility, but
    /// clipboard sharing is **only supported for Linux guests**
    /// via `VZSpiceAgentPortAttachment` (which requires
    /// `spice-vdagent` installed in the guest).
    ///
    /// macOS guests do not support clipboard synchronization
    /// through the Virtualization framework. When this property
    /// is `true` and the guest is macOS, a warning is logged and
    /// the setting is treated as a no-op.
    ///
    /// Defaults to `true`.
    public let clipboardSharingEnabled: Bool

    /// Whether to expose Rosetta 2 translation to the
    /// Linux guest via `VZLinuxRosettaDirectoryShare`.
    ///
    /// When `true` and ``guestOS`` is
    /// ``GuestOS/linux``, the host exposes its Rosetta
    /// runtime to the guest through a virtio-fs mount
    /// tagged `rosetta`.  Inside the guest the user (or
    /// a boot script) mounts the tag at `/mnt/rosetta`
    /// and registers the runtime with the kernel's
    /// binfmt subsystem — at that point every `exec()`
    /// of an `x86_64` ELF binary runs transparently
    /// under Rosetta without QEMU.
    ///
    /// Ignored for macOS guests; Rosetta on the host is
    /// a Linux-specific integration in the
    /// Virtualization framework.
    ///
    /// Requires Rosetta to be present on the host —
    /// callers should gate on
    /// `VZLinuxRosettaDirectoryShare.availability ==
    /// .installed` before setting this.
    ///
    /// Defaults to `false`.
    public let rosettaEnabled: Bool

    /// Creates a new virtual machine specification.
    ///
    /// - Parameters:
    ///   - cpuCount: Number of CPU cores. Clamped to a minimum
    ///     of ``minimumCPUCount`` (4).
    ///   - memorySizeInBytes: RAM in bytes. Defaults to 8 GiB.
    ///   - diskSizeInBytes: Disk image size in bytes. Defaults
    ///     to 64 GiB.
    ///   - displayCount: Number of displays (1–2). Defaults to 1.
    ///   - networkMode: Network mode. Defaults to ``NetworkMode/nat``.
    ///   - audioEnabled: Attach audio output device. Defaults to
    ///     `true`.
    ///   - microphoneEnabled: Attach microphone input. Defaults
    ///     to `false`. Ignored when `audioEnabled` is `false`.
    ///   - sharedFolders: Host directories to share with the guest.
    ///     Defaults to an empty array.
    ///   - macAddress: Explicit MAC address, or `nil` for
    ///     auto-generated. Defaults to `nil`.
    ///   - autoResizeDisplay: Resize guest display to match host
    ///     window. Defaults to `true`.
    ///   - clipboardSharingEnabled: Share clipboard between host
    ///     and guest. Only effective for Linux guests; macOS guests
    ///     log a warning and ignore this setting. Defaults to `true`.
    public init(
        cpuCount: Int = 4,
        memorySizeInBytes: UInt64 = 8 * 1024 * 1024 * 1024,
        diskSizeInBytes: UInt64 = 64 * 1024 * 1024 * 1024,
        displayCount: Int = 1,
        networkMode: NetworkMode = .nat,
        audioEnabled: Bool = true,
        microphoneEnabled: Bool = false,
        sharedFolders: [SharedFolder] = [],
        macAddress: MACAddress? = nil,
        autoResizeDisplay: Bool = true,
        clipboardSharingEnabled: Bool = true,
        storageController: StorageController = .virtio,
        additionalDisks: [AdditionalDisk] = [],
        networkBlockDevices: [NBDBackedDisk] = [],
        guestOS: GuestOS = .macOS,
        rosettaEnabled: Bool = false
    ) {
        // Guest-OS-aware CPU floor. macOS still wants 4
        // (the pre-existing empirical minimum); Linux can
        // run on a single core. Clamp each case to its own
        // floor so a caller passing `cpuCount: 1` with
        // `guestOS: .linux` gets a 1-CPU Linux VM instead
        // of silently being bumped to 4.
        self.cpuCount = max(cpuCount, guestOS.minimumCPUCount)
        self.memorySizeInBytes = memorySizeInBytes
        self.diskSizeInBytes = diskSizeInBytes
        self.displayCount = min(max(displayCount, 1), 2)
        self.networkMode = networkMode
        self.audioEnabled = audioEnabled
        self.microphoneEnabled = microphoneEnabled
        self.sharedFolders = sharedFolders
        self.macAddress = macAddress
        self.autoResizeDisplay = autoResizeDisplay
        self.clipboardSharingEnabled = clipboardSharingEnabled
        self.storageController = storageController
        self.additionalDisks = additionalDisks
        self.networkBlockDevices = networkBlockDevices
        self.guestOS = guestOS
        self.rosettaEnabled = rosettaEnabled
    }

    /// Decoder with `decodeIfPresent` on the new fields so
    /// existing bundles created before Track G shipped still
    /// load. The defaults match the primary-path behaviour
    /// (virtio, no secondary disks) so a decoded bundle keeps
    /// its current semantics if the keys are absent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode guestOS first — the CPU floor depends on it.
        // `decodeIfPresent` with `.macOS` as the fallback so
        // pre-Track-H bundles (which didn't carry this field)
        // keep their macOS behaviour.
        let decodedGuestOS = try container.decodeIfPresent(
            GuestOS.self, forKey: .guestOS
        ) ?? .macOS
        self.guestOS = decodedGuestOS
        self.cpuCount = max(
            try container.decode(Int.self, forKey: .cpuCount),
            decodedGuestOS.minimumCPUCount
        )
        self.memorySizeInBytes = try container.decode(UInt64.self, forKey: .memorySizeInBytes)
        self.diskSizeInBytes = try container.decode(UInt64.self, forKey: .diskSizeInBytes)
        let rawDisplayCount = try container.decode(Int.self, forKey: .displayCount)
        self.displayCount = min(max(rawDisplayCount, 1), 2)
        self.networkMode = try container.decode(NetworkMode.self, forKey: .networkMode)
        self.audioEnabled = try container.decode(Bool.self, forKey: .audioEnabled)
        self.microphoneEnabled = try container.decode(Bool.self, forKey: .microphoneEnabled)
        self.sharedFolders = try container.decode([SharedFolder].self, forKey: .sharedFolders)
        self.macAddress = try container.decodeIfPresent(MACAddress.self, forKey: .macAddress)
        self.autoResizeDisplay = try container.decode(Bool.self, forKey: .autoResizeDisplay)
        self.clipboardSharingEnabled = try container.decode(Bool.self, forKey: .clipboardSharingEnabled)

        // `decodeIfPresent` with defaults — absent keys mean
        // "pre-Track-G / pre-Track-K bundle", so fall back
        // to the pre-Track behaviour (virtio, no extra
        // disks, no NBD).
        self.storageController = try container.decodeIfPresent(
            StorageController.self, forKey: .storageController
        ) ?? .virtio
        self.additionalDisks = try container.decodeIfPresent(
            [AdditionalDisk].self, forKey: .additionalDisks
        ) ?? []
        self.networkBlockDevices = try container.decodeIfPresent(
            [NBDBackedDisk].self, forKey: .networkBlockDevices
        ) ?? []
        // Pre-Track-H.4 bundles predate Rosetta — default
        // `false` so they keep their original (non-Rosetta)
        // device graph.
        self.rosettaEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .rosettaEnabled
        ) ?? false
    }

    /// Returns a copy of this specification with different shared folders.
    ///
    /// All other properties are preserved unchanged.
    ///
    /// ```swift
    /// let updated = spec.withSharedFolders(spec.sharedFolders + [newFolder])
    /// ```
    ///
    /// - Parameter folders: The new shared folders list.
    /// - Returns: A new specification identical to this one except
    ///   for shared folders.
    public func withSharedFolders(_ folders: [SharedFolder]) -> VirtualMachineSpecification {
        with(sharedFolders: folders)
    }

    /// Returns a copy of this specification with any subset of
    /// fields overridden.
    ///
    /// Fields you omit (or pass `nil` for) retain their current
    /// values. The ``macAddress`` field uses ``MacAddressOverride``
    /// rather than a double-optional — `MACAddress??` is syntactically
    /// valid Swift but produces call sites where `.some(nil)` (clear)
    /// and `.none` (keep) are effectively indistinguishable to a
    /// reader.
    ///
    /// ```swift
    /// let stable = spec.with(macAddress: .set(MACAddress("aa:bb:cc:dd:ee:ff")!))
    /// let cleared = spec.with(macAddress: .clear)
    /// let same    = spec.with(cpuCount: 8)            // macAddress unchanged
    /// ```
    ///
    /// - Parameters:
    ///   - cpuCount: Number of CPU cores.
    ///   - memorySizeInBytes: RAM in bytes.
    ///   - diskSizeInBytes: Disk image size in bytes.
    ///   - displayCount: Number of displays.
    ///   - networkMode: Network mode.
    ///   - audioEnabled: Attach audio output device.
    ///   - microphoneEnabled: Attach microphone input.
    ///   - sharedFolders: Host directories to share.
    ///   - macAddress: Explicit MAC address override directive.
    ///     Defaults to ``MacAddressOverride/omit``.
    ///   - autoResizeDisplay: Resize guest display to match host.
    ///   - clipboardSharingEnabled: Share clipboard.
    /// - Returns: A new specification with the overridden values.
    public func with(
        cpuCount: Int? = nil,
        memorySizeInBytes: UInt64? = nil,
        diskSizeInBytes: UInt64? = nil,
        displayCount: Int? = nil,
        networkMode: NetworkMode? = nil,
        audioEnabled: Bool? = nil,
        microphoneEnabled: Bool? = nil,
        sharedFolders: [SharedFolder]? = nil,
        macAddress: MacAddressOverride = .omit,
        autoResizeDisplay: Bool? = nil,
        clipboardSharingEnabled: Bool? = nil,
        storageController: StorageController? = nil,
        additionalDisks: [AdditionalDisk]? = nil,
        networkBlockDevices: [NBDBackedDisk]? = nil,
        guestOS: GuestOS? = nil,
        rosettaEnabled: Bool? = nil
    ) -> VirtualMachineSpecification {
        VirtualMachineSpecification(
            cpuCount: cpuCount ?? self.cpuCount,
            memorySizeInBytes: memorySizeInBytes ?? self.memorySizeInBytes,
            diskSizeInBytes: diskSizeInBytes ?? self.diskSizeInBytes,
            displayCount: displayCount ?? self.displayCount,
            networkMode: networkMode ?? self.networkMode,
            audioEnabled: audioEnabled ?? self.audioEnabled,
            microphoneEnabled: microphoneEnabled ?? self.microphoneEnabled,
            sharedFolders: sharedFolders ?? self.sharedFolders,
            macAddress: macAddress.resolved(from: self.macAddress),
            autoResizeDisplay: autoResizeDisplay ?? self.autoResizeDisplay,
            clipboardSharingEnabled: clipboardSharingEnabled ?? self.clipboardSharingEnabled,
            storageController: storageController ?? self.storageController,
            additionalDisks: additionalDisks ?? self.additionalDisks,
            networkBlockDevices: networkBlockDevices ?? self.networkBlockDevices,
            guestOS: guestOS ?? self.guestOS,
            rosettaEnabled: rosettaEnabled ?? self.rosettaEnabled
        )
    }

    /// Validates the specification against the documented hardware
    /// bounds before the bundle layer writes `config.json` to disk.
    ///
    /// Checked invariants:
    /// - CPU count is at least ``minimumCPUCount`` (4).
    /// - Memory is at least 1 GiB and strictly less than 1 TiB.
    /// - Disk size is at least 1 GiB.
    /// - Display count is 1 or 2.
    ///
    /// - Throws: ``VirtualMachineSpecificationError`` describing the
    ///   first bound the spec violates.
    public func validate() throws {
        // Guest-OS-specific CPU floor. macOS still requires
        // 4 cores (empirical — fewer causes boot hangs);
        // Linux can boot on 1. The initializer already
        // clamps to this floor, so `validate()` is a
        // belt-and-braces check that also catches
        // hand-decoded specs that bypassed `init(from:)`.
        let cpuFloor = guestOS.minimumCPUCount
        guard cpuCount >= cpuFloor else {
            throw VirtualMachineSpecificationError.cpuCountTooLow(
                provided: cpuCount,
                minimum: cpuFloor
            )
        }
        let oneGiB: UInt64 = 1 << 30
        let oneTiB: UInt64 = 1 << 40
        guard memorySizeInBytes >= oneGiB else {
            throw VirtualMachineSpecificationError.memoryTooLow(
                provided: memorySizeInBytes,
                minimum: oneGiB
            )
        }
        guard memorySizeInBytes < oneTiB else {
            throw VirtualMachineSpecificationError.memoryTooHigh(
                provided: memorySizeInBytes,
                maximum: oneTiB
            )
        }
        guard diskSizeInBytes >= oneGiB else {
            throw VirtualMachineSpecificationError.diskTooSmall(
                provided: diskSizeInBytes,
                minimum: oneGiB
            )
        }
        guard (1...2).contains(displayCount) else {
            throw VirtualMachineSpecificationError.displayCountOutOfRange(
                provided: displayCount
            )
        }
    }

    // MARK: - Convenience Properties

    /// The memory size in whole gigabytes (GiB).
    public var memorySizeInGigabytes: UInt64 {
        memorySizeInBytes / (1024 * 1024 * 1024)
    }

    /// The disk size in whole gigabytes (GiB).
    public var diskSizeInGigabytes: UInt64 {
        diskSizeInBytes / (1024 * 1024 * 1024)
    }
}

// MARK: - MacAddressOverride

/// Explicit, three-way directive for the `macAddress` field in
/// ``VirtualMachineSpecification/with(cpuCount:memorySizeInBytes:diskSizeInBytes:displayCount:networkMode:audioEnabled:microphoneEnabled:sharedFolders:macAddress:autoResizeDisplay:clipboardSharingEnabled:)``.
///
/// Replaces `MACAddress??`, where `.some(nil)` (clear) and `.none`
/// (keep) were syntactically distinct but visually ambiguous at the
/// call site. Every override action now has its own named case.
public enum MacAddressOverride: Sendable, Equatable {

    /// Retain the current MAC address value. The default — matches
    /// "I didn't pass anything for this field."
    case omit

    /// Set the MAC address explicitly.
    ///
    /// - Parameter address: The explicit ``MACAddress`` to apply.
    case set(MACAddress)

    /// Clear the MAC address so the Virtualization framework
    /// auto-generates one on VM start.
    case clear

    /// Resolves the override against the current value from the
    /// owning spec, returning the new effective value.
    func resolved(from current: MACAddress?) -> MACAddress? {
        switch self {
        case .omit:              return current
        case .set(let address):  return address
        case .clear:             return nil
        }
    }
}

// MARK: - Specification errors

/// Errors raised by ``VirtualMachineSpecification/validate()`` when
/// a spec violates a documented hardware bound.
public enum VirtualMachineSpecificationError: Error, Sendable, Equatable, LocalizedError {

    /// CPU count is below the documented minimum.
    case cpuCountTooLow(provided: Int, minimum: Int)

    /// Memory is below 1 GiB.
    case memoryTooLow(provided: UInt64, minimum: UInt64)

    /// Memory equals or exceeds 1 TiB — likely a byte/GB unit bug.
    case memoryTooHigh(provided: UInt64, maximum: UInt64)

    /// Disk size is below 1 GiB.
    case diskTooSmall(provided: UInt64, minimum: UInt64)

    /// Display count is not 1 or 2.
    case displayCountOutOfRange(provided: Int)

    public var errorDescription: String? {
        switch self {
        case .cpuCountTooLow(let p, let m):
            "CPU count \(p) is below the minimum \(m) for macOS guests."
        case .memoryTooLow(let p, let m):
            "Memory \(p) bytes is below the minimum \(m) bytes (1 GiB)."
        case .memoryTooHigh(let p, let m):
            "Memory \(p) bytes is at or above \(m) bytes (1 TiB) — likely a unit conversion bug."
        case .diskTooSmall(let p, let m):
            "Disk size \(p) bytes is below the minimum \(m) bytes (1 GiB)."
        case .displayCountOutOfRange(let p):
            "Display count \(p) is not in the accepted range 1...2."
        }
    }

    public var recoverySuggestion: String? {
        "Adjust the spec and retry. See VirtualMachineSpecification docs for the accepted ranges."
    }
}

// MARK: - UInt64 Convenience

extension UInt64 {

    /// Returns the number of bytes in the given number of gibibytes (GiB).
    ///
    /// One gibibyte is 1,073,741,824 bytes (1024^3). This helper
    /// eliminates magic-number multiplication when specifying memory
    /// and disk sizes.
    ///
    /// ```swift
    /// let eightGiB = UInt64.gigabytes(8) // 8_589_934_592
    /// ```
    ///
    /// - Parameter count: The number of gibibytes.
    /// - Returns: The equivalent byte count.
    public static func gigabytes(_ count: some BinaryInteger) -> UInt64 {
        UInt64(count) &* 1_073_741_824
    }
}

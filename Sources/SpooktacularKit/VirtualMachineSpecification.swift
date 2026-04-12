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
    /// MAC address. Set this to a valid MAC string (e.g.
    /// `"AA:BB:CC:DD:EE:FF"`) when you need a stable network
    /// identity across reboots. Defaults to `nil`.
    public let macAddress: String?

    /// Whether the guest display automatically resizes to match
    /// the host window.
    ///
    /// Defaults to `true`. This hint is consumed by the display
    /// layer — the Virtualization framework itself always creates
    /// fixed-resolution displays.
    public let autoResizeDisplay: Bool

    /// Whether the host and guest share a common clipboard.
    ///
    /// When `true`, copy-paste operations propagate between the
    /// host and the guest. Defaults to `true`.
    public let clipboardSharingEnabled: Bool

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
    ///   - macAddress: Explicit MAC address string, or `nil` for
    ///     auto-generated. Defaults to `nil`.
    ///   - autoResizeDisplay: Resize guest display to match host
    ///     window. Defaults to `true`.
    ///   - clipboardSharingEnabled: Share clipboard between host
    ///     and guest. Defaults to `true`.
    public init(
        cpuCount: Int = 4,
        memorySizeInBytes: UInt64 = 8 * 1024 * 1024 * 1024,
        diskSizeInBytes: UInt64 = 64 * 1024 * 1024 * 1024,
        displayCount: Int = 1,
        networkMode: NetworkMode = .nat,
        audioEnabled: Bool = true,
        microphoneEnabled: Bool = false,
        sharedFolders: [SharedFolder] = [],
        macAddress: String? = nil,
        autoResizeDisplay: Bool = true,
        clipboardSharingEnabled: Bool = true
    ) {
        self.cpuCount = max(cpuCount, Self.minimumCPUCount)
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
    }
}

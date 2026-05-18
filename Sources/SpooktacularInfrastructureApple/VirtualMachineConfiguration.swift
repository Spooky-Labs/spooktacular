import Foundation
import SpooktacularCore
import SpooktacularApplication
import os
@preconcurrency import Virtualization

/// Errors that can occur when configuring network devices.
public enum NetworkConfigurationError: Error, Sendable, Equatable, LocalizedError {
    /// The requested bridge interface was not found on the host.
    case bridgeInterfaceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .bridgeInterfaceNotFound(let name):
            "Bridge interface '\(name)' not found."
        }
    }

    public var recoverySuggestion: String? {
        "Check the interface name with 'networksetup -listallhardwareports'. Use 'nat' or 'isolated' if bridged is not needed."
    }
}

/// Errors that can occur when configuring storage devices.
public enum StorageConfigurationError: Error, Sendable, Equatable, LocalizedError {
    /// The spec requests NVM Express storage, but the VM's
    /// platform is macOS. Apple's
    /// `VZNVMExpressControllerDeviceConfiguration` header
    /// restricts the device to `VZGenericPlatformConfiguration`
    /// (Linux guests only).
    case nvmeRequiresLinux

    /// The spec pairs an NBD-backed disk with `bus: .usb`.
    /// `VZUSBMassStorageDeviceConfiguration` only accepts
    /// disk-image-backed attachments, not
    /// `VZNetworkBlockDeviceStorageDeviceAttachment`.
    case nbdNotSupportedOnUSB

    public var errorDescription: String? {
        switch self {
        case .nvmeRequiresLinux:
            "NVMe storage controllers require a Linux guest. The Virtualization framework only accepts VZNVMExpressControllerDeviceConfiguration alongside VZGenericPlatformConfiguration."
        case .nbdNotSupportedOnUSB:
            "NBD-backed disks cannot be exposed through a USB mass-storage controller. The framework's VZUSBMassStorageDeviceConfiguration only accepts disk-image attachments."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .nvmeRequiresLinux:
            "Set the storage controller to `virtio` for this macOS guest. NVMe becomes available when Track H (Linux guests) ships."
        case .nbdNotSupportedOnUSB:
            "Attach this NBD disk on the virtio bus. USB is reserved for image-file disks only."
        }
    }
}

/// Builds `VZVirtualMachineConfiguration` objects from a ``VirtualMachineSpecification``.
///
/// `VirtualMachineConfiguration` translates the product-level specification
/// (CPU count, memory, display count, network mode) into the
/// corresponding Virtualization framework configuration objects.
///
/// The ``applySpec(_:to:)`` method sets CPU, memory, boot loader,
/// graphics, input, network, socket, and entropy
/// devices on a mutable `VZVirtualMachineConfiguration`.
/// Platform configuration
/// (hardware model, machine identifier, auxiliary storage) and
/// storage devices (disk images) are set separately because they
/// require VM-specific artifacts from disk.
///
/// ## Usage
///
/// ```swift
/// let config = VZVirtualMachineConfiguration()
///
/// // Apply spec-derived settings.
/// try VirtualMachineConfiguration.applySpec(spec, to: config)
///
/// // Apply platform and storage from bundle artifacts.
/// config.platform = platform
/// config.storageDevices = [diskDevice]
///
/// try config.validate()
/// ```
public enum VirtualMachineConfiguration {

    /// Default display resolution for virtual screens.
    private static let displayWidth = 1920
    private static let displayHeight = 1200
    private static let displayPPI = 80

    /// Applies a ``VirtualMachineSpecification`` to a `VZVirtualMachineConfiguration`.
    ///
    /// This sets all spec-derived properties: CPU, memory,
    /// boot loader, graphics, input devices, network, socket,
    /// and entropy. It does **not** set
    /// `platform` or `storageDevices` — those require
    /// bundle-specific artifacts.
    ///
    /// - Parameters:
    ///   - spec: The hardware specification.
    ///   - configuration: The mutable configuration to populate.
    /// - Throws: ``NetworkConfigurationError/bridgeInterfaceNotFound(_:)``
    ///   if bridged networking is requested but the interface does not exist.
    public static func applySpec(
        _ spec: VirtualMachineSpecification,
        to configuration: VZVirtualMachineConfiguration
    ) throws {
        Log.config.info("Applying spec: \(spec.cpuCount) CPU, \(spec.memorySizeInBytes / (1024*1024*1024)) GB RAM, \(spec.displayCount) display(s)")

        configuration.cpuCount = spec.cpuCount
        configuration.memorySize = spec.memorySizeInBytes

        // Guest-OS-specific device graph (Track H). The
        // framework requires `VZMacOSBootLoader` paired with
        // Mac-specific keyboard/trackpad/graphics, and
        // `VZEFIBootLoader` paired with USB keyboard/mouse +
        // virtio graphics + an XHCI controller. Mixing the two
        // shapes fails `configuration.validate()` at runtime.
        switch spec.guestOS {
        case .macOS:
            configuration.bootLoader = VZMacOSBootLoader()
            configuration.graphicsDevices = [makeMacGraphics(displayCount: spec.displayCount)]
            configuration.keyboards = [VZMacKeyboardConfiguration()]
            configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        case .linux:
            // EFI boot loader. `variableStore` is wired in by
            // `applyPlatform(from:to:)` when the bundle has an
            // `efi-nvram.bin` artifact (Track H.2). With no
            // NVRAM the firmware boots in "no NVRAM" mode,
            // fine for a first-boot installer ISO.
            configuration.bootLoader = VZEFIBootLoader()
            configuration.graphicsDevices = [makeLinuxGraphics(displayCount: spec.displayCount)]
            configuration.keyboards = [VZUSBKeyboardConfiguration()]
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            // Linux configurations always get an XHCI
            // controller.  Apple's
            // `VZUSBMassStorageDeviceConfiguration`
            // documentation is explicit: *"Be sure to add a
            // VZUSBControllerConfiguration to your
            // configuration to provide a USB controller."*
            // Without it the installer ISO is listed in
            // `storageDevices` but has no bus to terminate
            // on; EFI never enumerates the device, the
            // firmware exhausts its BootOrder against the
            // empty primary disk, and the VM exits cleanly
            // with a black screen.  The XHCI controller
            // also backs the USB keyboard and pointing
            // device we just configured.  `applyStorage`
            // appends additional USB disks to the same
            // controller instance when they're present.
            //
            // Reference: [VZUSBMassStorageDeviceConfiguration](https://developer.apple.com/documentation/virtualization/vzusbmassstoragedeviceconfiguration)
            configuration.usbControllers = [VZXHCIControllerConfiguration()]

            // No default serial port.  Apple's "Running GUI
            // Linux in a VM on a Mac" sample does not wire
            // one, and for Linux guests the presence of a
            // VirtIO serial console creates `/dev/hvc0` in
            // the guest, which `systemd-getty-generator`
            // picks up to spawn `serial-getty@hvc0.service`
            // as an interactive console.  On Fedora Live
            // that flip routes the primary console off tty1,
            // which in turn keeps `gdm` / `gnome-session` /
            // the `livesys` auto-login path from starting —
            // the guest boots to a text-mode getty on hvc0
            // and the virtio-gpu scanout never paints.
            //
            // If we need boot-time kernel diagnostics in the
            // future, add an opt-in `--serial` CLI flag that
            // wires a serial port explicitly; never do it by
            // default.
        }

        configuration.networkDevices = try makeNetworkDevices(
            for: spec.networkMode, macAddress: spec.macAddress
        )
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [
            VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        ]

        if spec.audioEnabled {
            configuration.audioDevices = makeAudioDevices(
                guestOS: spec.guestOS,
                microphone: spec.microphoneEnabled
            )
        }

        var directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = []
        if !spec.sharedFolders.isEmpty {
            directorySharingDevices.append(contentsOf: makeSharing(spec.sharedFolders))
        }

        // Rosetta for Linux (Track H.4).  Exposes the host's
        // Rosetta 2 runtime to a Linux guest through a
        // dedicated virtio-fs mount.  Once the guest mounts
        // the tag and registers the runtime with binfmt
        // (see `Running Intel Binaries in Linux VMs with
        // Rosetta`), every `x86_64` ELF executed in the
        // guest runs transparently through Rosetta with no
        // QEMU, no userland emulator.  Macos-only tools
        // like OpenCL, CUDA translation are out of scope;
        // this is pure CPU-instruction translation of
        // Intel user binaries on an ARM kernel.
        //
        // Silent-no-op rules:
        // - macOS guests: Rosetta is a Linux-only
        //   integration in `VZ`; we log and skip.
        // - Rosetta not installed on host: `init()`
        //   throws.  We log and skip instead of failing
        //   the whole VM create — the guest still boots,
        //   just without x86 support.  Operators who
        //   *require* Rosetta should gate VM creation on
        //   `VZLinuxRosettaDirectoryShare.availability ==
        //   .installed` before calling this.
        //
        // Reference:
        // - [VZLinuxRosettaDirectoryShare](https://developer.apple.com/documentation/virtualization/vzlinuxrosettadirectoryshare)
        // - [Running Intel Binaries in Linux VMs with Rosetta](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms-with-rosetta)
        if spec.rosettaEnabled, spec.guestOS == .linux {
            if VZLinuxRosettaDirectoryShare.availability == .installed {
                do {
                    let rosettaShare = try VZLinuxRosettaDirectoryShare()
                    let rosettaTag = "rosetta"
                    let rosettaDevice = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
                    rosettaDevice.share = rosettaShare
                    directorySharingDevices.append(rosettaDevice)
                    Log.config.info("Rosetta directory share attached as virtio-fs tag '\(rosettaTag, privacy: .public)'")
                } catch {
                    Log.config.warning("VZLinuxRosettaDirectoryShare() threw: \(String(describing: error), privacy: .public). Guest boots without Rosetta.")
                }
            } else {
                Log.config.warning("Rosetta requested but not installed on host (VZLinuxRosettaDirectoryShare.availability != .installed). Guest boots without Rosetta.")
            }
        }

        if !directorySharingDevices.isEmpty {
            configuration.directorySharingDevices = directorySharingDevices
        }

        // ────── Clipboard sharing ──────
        //
        // Apple's supported clipboard-sharing path is
        // `VZSpiceAgentPortAttachment` (macOS 13.0+). It relays
        // the host pasteboard into a named VirtIO console port
        // (`com.redhat.spice.0`) that the SPICE vdagent inside
        // the guest reads. On Linux guests this Just Works once
        // `spice-vdagent` is installed; on macOS guests there's
        // no `spice-vdagent` implementation so the port stays
        // attached but idle — that's where our existing vsock
        // `ClipboardBridge` (in the GUI layer) takes over.
        //
        // Attaching unconditionally when the spec asks for
        // clipboard sharing is safe: the port costs essentially
        // nothing on the guest side if no vdagent connects, and
        // it lets Linux guests sync without any per-guest-OS
        // branching on the host.
        //
        // Docs:
        // - https://developer.apple.com/documentation/virtualization/clipboard-sharing
        // - https://developer.apple.com/documentation/virtualization/vzspiceagentportattachment
        if spec.clipboardSharingEnabled {
            configuration.consoleDevices.append(makeSpiceClipboardConsole())
        }
    }

    /// Builds a VirtIO console device carrying a single SPICE
    /// agent port with clipboard sharing enabled.
    ///
    /// Port name comes from
    /// `VZSpiceAgentPortAttachment.spiceAgentPortName` (the
    /// `com.redhat.spice.0` constant the vdagent looks for), so
    /// callers never hard-code the magic string.
    private static func makeSpiceClipboardConsole() -> VZVirtioConsoleDeviceConfiguration {
        let attachment = VZSpiceAgentPortAttachment()
        attachment.sharesClipboard = true

        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        port.attachment = attachment

        let device = VZVirtioConsoleDeviceConfiguration()
        device.ports[0] = port
        return device
    }

    private static func makeMacGraphics(
        displayCount: Int
    ) -> VZMacGraphicsDeviceConfiguration {
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = (0..<displayCount).map { _ in
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: displayWidth,
                heightInPixels: displayHeight,
                pixelsPerInch: displayPPI
            )
        }
        return graphics
    }

    /// Linux-flavoured graphics: virtio-gpu exposed through one
    /// scanout per configured display. Mirrors the Mac path
    /// (same `displayWidth`/`displayHeight`) so the workspace
    /// window reports identical dimensions regardless of guest
    /// OS. `VZVirtioGraphicsScanoutConfiguration` does NOT
    /// accept a pixelsPerInch value — only raw pixel dimensions.
    private static func makeLinuxGraphics(
        displayCount: Int
    ) -> VZVirtioGraphicsDeviceConfiguration {
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = (0..<displayCount).map { _ in
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: displayWidth,
                heightInPixels: displayHeight
            )
        }
        return graphics
    }

    /// Builds sound-device configurations for the current
    /// guest OS.
    ///
    /// Apple's samples diverge by guest:
    ///
    /// - **macOS** (`Running macOS in a virtual machine on
    ///   Apple silicon`) — one `VZVirtioSoundDeviceConfiguration`
    ///   that carries both output and (optional) input
    ///   streams on a single device.  Matches the `audio`
    ///   port shape macOS guests expect from the host's
    ///   CoreAudio bridge.
    /// - **Linux** (`Running GUI Linux in a VM on a Mac`) —
    ///   two separate `VZVirtioSoundDeviceConfiguration`
    ///   instances, one output-only and one input-only.
    ///   PulseAudio / PipeWire inside the guest enumerates
    ///   them as two independent cards, which is the shape
    ///   their ALSA / virtio-snd bindings were validated
    ///   against.  Mixing input + output streams onto a
    ///   single device works on macOS guests but is the
    ///   non-canonical form on Linux — avoid it.
    private static func makeAudioDevices(
        guestOS: GuestOS,
        microphone: Bool
    ) -> [VZVirtioSoundDeviceConfiguration] {
        switch guestOS {
        case .macOS:
            let device = VZVirtioSoundDeviceConfiguration()
            device.streams = microphone
                ? [VZVirtioSoundDeviceOutputStreamConfiguration(), VZVirtioSoundDeviceInputStreamConfiguration()]
                : [VZVirtioSoundDeviceOutputStreamConfiguration()]
            return [device]
        case .linux:
            let output = VZVirtioSoundDeviceConfiguration()
            output.streams = [VZVirtioSoundDeviceOutputStreamConfiguration()]
            guard microphone else { return [output] }
            let input = VZVirtioSoundDeviceConfiguration()
            input.streams = [VZVirtioSoundDeviceInputStreamConfiguration()]
            return [output, input]
        }
    }

    /// Builds VirtIO file-system devices for shared folders.
    ///
    /// For a single folder, returns one device tagged with
    /// ``VZVirtioFileSystemDeviceConfiguration/macOSGuestAutomountTag``
    /// so it appears automatically in Finder. For multiple folders,
    /// returns one device per folder, each tagged with the folder's
    /// ``SharedFolder/tag`` so the guest can mount them individually.
    ///
    /// - Parameter folders: The shared folder specifications.
    ///   Must not be empty.
    /// - Returns: An array of configured file-system devices.
    private static func makeSharing(
        _ folders: [SharedFolder]
    ) -> [VZVirtioFileSystemDeviceConfiguration] {
        if folders.count == 1 {
            let folder = folders[0]
            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(
                    url: URL(filePath: folder.hostPath),
                    readOnly: folder.readOnly
                )
            )
            let device = VZVirtioFileSystemDeviceConfiguration(
                tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
            )
            device.share = share
            return [device]
        }

        return folders.map { folder in
            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(
                    url: URL(filePath: folder.hostPath),
                    readOnly: folder.readOnly
                )
            )
            let device = VZVirtioFileSystemDeviceConfiguration(tag: folder.tag)
            device.share = share
            return device
        }
    }

    /// Applies platform-specific configuration from bundle artifacts.
    ///
    /// Reads the hardware model, machine identifier, and auxiliary
    /// storage files from a ``VirtualMachineBundle`` and sets them on the
    /// configuration's `platform` property.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle containing platform artifact files.
    ///   - configuration: The mutable configuration to populate.
    /// - Throws: ``VirtualMachineBundleError/invalidConfiguration(url:)`` if
    ///   the platform artifacts cannot be loaded.
    public static func applyPlatform(
        from bundle: VirtualMachineBundle,
        to configuration: VZVirtualMachineConfiguration
    ) throws {
        Log.config.debug("Loading platform artifacts from \(bundle.url.lastPathComponent, privacy: .public)")

        // `VZVirtualMachineConfiguration` accepts exactly one
        // of `VZMacPlatformConfiguration` or
        // `VZGenericPlatformConfiguration` — the platform
        // type must match the boot loader set in
        // `applySpec`. Branch on the spec's guestOS to stay
        // consistent.
        switch bundle.spec.guestOS {
        case .macOS:
            try applyMacPlatform(from: bundle, to: configuration)
        case .linux:
            // Linux guests use the generic platform. No
            // hardware model / aux storage to load — those
            // are Mac-specific. The machine identifier is
            // loaded from the bundle if present (provisioned
            // at create time), giving the VM a stable
            // identity across reboots so EFI NVRAM boot
            // entries don't go stale.
            let platform = VZGenericPlatformConfiguration()
            let machineIDURL = bundle.url.appendingPathComponent(
                VirtualMachineBundle.machineIdentifierFileName
            )
            if FileManager.default.fileExists(atPath: machineIDURL.path),
               let idData = try? Data(contentsOf: machineIDURL),
               let id = VZGenericMachineIdentifier(dataRepresentation: idData) {
                platform.machineIdentifier = id
                Log.config.debug("Loaded generic machine identifier for \(bundle.url.lastPathComponent, privacy: .public)")
            }
            configuration.platform = platform

            // Load the EFI NVRAM variable store the bundle
            // provisioned at creation time. This lets the
            // firmware remember the next-boot entry and any
            // OS-written EFI variables across reboots;
            // without it, every boot restarts fresh (fine
            // for installer ISOs, catastrophic once installed
            // since GRUB's boot record lives here).
            //
            // Nested-if order matters: applySpec set the
            // VZEFIBootLoader; cast back to mutate the
            // variableStore property without rebuilding the
            // whole boot loader.
            if bundle.hasEFIVariableStore,
               let efi = configuration.bootLoader as? VZEFIBootLoader {
                efi.variableStore = VZEFIVariableStore(url: bundle.efiVariableStoreURL)
                Log.config.debug("Attached EFI NVRAM for \(bundle.url.lastPathComponent, privacy: .public)")
            }

            Log.config.debug("Linux generic platform applied for \(bundle.url.lastPathComponent, privacy: .public)")
        }
    }

    /// macOS platform assembly — unchanged from before
    /// Track H. Extracted so the branch in
    /// ``applyPlatform(from:to:)`` stays readable.
    private static func applyMacPlatform(
        from bundle: VirtualMachineBundle,
        to configuration: VZVirtualMachineConfiguration
    ) throws {
        let platform = VZMacPlatformConfiguration()

        let hardwareModelData = try Data(
            contentsOf: bundle.url.appendingPathComponent(VirtualMachineBundle.hardwareModelFileName)
        )
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            Log.config.error("Invalid hardware model in \(bundle.url.lastPathComponent, privacy: .public)")
            throw VirtualMachineBundleError.invalidConfiguration(url: bundle.url)
        }
        platform.hardwareModel = hardwareModel

        let machineIdentifierData = try Data(
            contentsOf: bundle.url.appendingPathComponent(VirtualMachineBundle.machineIdentifierFileName)
        )
        guard let machineIdentifier = VZMacMachineIdentifier(
            dataRepresentation: machineIdentifierData
        ) else {
            Log.config.error("Invalid machine identifier in \(bundle.url.lastPathComponent, privacy: .public)")
            throw VirtualMachineBundleError.invalidConfiguration(url: bundle.url)
        }
        platform.machineIdentifier = machineIdentifier

        let auxiliaryStorageURL = bundle.url.appendingPathComponent(VirtualMachineBundle.auxiliaryStorageFileName)
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxiliaryStorageURL)

        configuration.platform = platform
        Log.config.debug("Mac platform artifacts loaded for \(bundle.url.lastPathComponent, privacy: .public)")
    }

    /// Applies storage device configuration from a bundle's disk image.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle containing the disk image.
    ///   - configuration: The mutable configuration to populate.
    /// Builds `configuration.storageDevices` and
    /// `configuration.usbControllers` from `bundle.spec` and
    /// returns the list of ``NBDAttachmentMonitor`` delegates
    /// that must be retained by the caller — the framework
    /// holds `VZNetworkBlockDeviceStorageDeviceAttachment.delegate`
    /// weakly, so a caller that drops the monitors misses
    /// connect / error callbacks on the underlying NBD
    /// attachment.
    @discardableResult
    public static func applyStorage(
        from bundle: VirtualMachineBundle,
        to configuration: VZVirtualMachineConfiguration
    ) throws -> [NBDAttachmentMonitor] {
        Log.config.debug("Attaching disk image from \(bundle.url.lastPathComponent, privacy: .public)")
        let diskURL = bundle.url.appendingPathComponent(VirtualMachineBundle.diskImageFileName)

        var devices: [VZStorageDeviceConfiguration] = []

        // When an installer ISO is present, add it FIRST in
        // storageDevices so EFI's default boot-order logic
        // tries it before the (empty) primary disk on a
        // fresh install. This matches Apple's "Running GUI
        // Linux in a VM on a Mac" sample, which does:
        //   if needsInstall { add(installer); add(disk) }
        //   else            { add(disk) }
        // Without this ordering the firmware sits idle at
        // the empty boot target and no graphics ever render.
        if bundle.hasInstallerISO {
            devices.append(try makeInstallerISODevice(bundle: bundle))
        }

        devices.append(try makeStorageDevice(
            url: diskURL,
            readOnly: false,
            controller: bundle.spec.storageController
        ))
        var nbdMonitors: [NBDAttachmentMonitor] = []

        // Additional (secondary) disks from Track G. Each
        // carries its own `SecondaryDiskBus` so a single VM
        // can mix virtio + NVMe + USB mass storage. USB-bus
        // disks are hoisted to `usbControllers` below rather
        // than `storageDevices` because the framework
        // demands the XHCI-controller wiring.
        var usbDisks: [AdditionalDisk] = []
        for disk in bundle.spec.additionalDisks {
            let url = URL(filePath: disk.hostPath)
            switch disk.bus {
            case .virtio:
                devices.append(try makeStorageDevice(
                    url: url, readOnly: disk.readOnly, controller: .virtio
                ))
            case .nvme:
                devices.append(try makeStorageDevice(
                    url: url, readOnly: disk.readOnly, controller: .nvme
                ))
            case .usb:
                usbDisks.append(disk)
            }
        }

        // NBD-backed disks (Track K). Each becomes a
        // `VZNetworkBlockDeviceStorageDeviceAttachment`
        // wrapped in either a virtio-blk or NVMe device per
        // the spec's `bus`. The `.usb` bus is rejected
        // because `VZUSBMassStorageDeviceConfiguration`'s
        // attachment type is a concrete disk-image subclass
        // — the framework refuses an NBD attachment there.
        for disk in bundle.spec.networkBlockDevices {
            let device = try makeNBDStorageDevice(disk: disk, monitors: &nbdMonitors)
            devices.append(device)
        }

        configuration.storageDevices = devices

        // USB mass-storage disks from Track G's additionalDisks
        // spec (user-attached USB drives, distinct from the
        // installer ISO). These go through an XHCI controller
        // because they're hot-pluggable peripheral storage,
        // not boot devices.
        if !usbDisks.isEmpty {
            let xhci: VZUSBControllerConfiguration
            if let existing = configuration.usbControllers.first {
                xhci = existing
            } else {
                let fresh = VZXHCIControllerConfiguration()
                configuration.usbControllers = [fresh]
                xhci = fresh
            }
            xhci.usbDevices.append(contentsOf: try usbDisks.map { disk in
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: URL(filePath: disk.hostPath),
                    readOnly: disk.readOnly
                )
                return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
            })
        }

        return nbdMonitors
    }

    /// Builds a read-only USB mass-storage attachment for the
    /// Linux installer ISO. Read-only so the installer can't
    /// scribble on it — important for the repeatable first-
    /// boot install flow and for letting multiple VMs share
    /// the same ISO on disk.
    private static func makeInstallerISODevice(
        bundle: VirtualMachineBundle
    ) throws -> VZUSBMassStorageDeviceConfiguration {
        Log.config.debug("Attaching installer ISO for \(bundle.url.lastPathComponent, privacy: .public)")
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: bundle.installerISOURL,
            readOnly: true
        )
        return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
    }

    /// Builds one NBD-backed storage device: constructs the
    /// attachment, wires a ``NBDAttachmentMonitor`` delegate
    /// (returned via `monitors` so the caller can retain
    /// it), then wraps in virtio-blk or NVMe per the disk's
    /// bus.
    ///
    /// ## Apple APIs
    ///
    /// - [`VZNetworkBlockDeviceStorageDeviceAttachment(url:timeout:isForcedReadOnly:synchronizationMode:)`](https://developer.apple.com/documentation/virtualization/vznetworkblockdevicestoragedeviceattachment/init(url:timeout:isforcedreadonly:synchronizationmode:))
    ///   — throwing init with full parameters.
    /// - [`VZNetworkBlockDeviceStorageDeviceAttachment(url:)`](https://developer.apple.com/documentation/virtualization/vznetworkblockdevicestoragedeviceattachment/init(url:))
    ///   — convenience init with Apple-chosen defaults. We
    ///   use the full init whenever the spec overrides any
    ///   default so the wire-visible parameters are
    ///   auditable.
    /// - [`VZNetworkBlockDeviceStorageDeviceAttachment.validateURL(_:)`](https://developer.apple.com/documentation/virtualization/vznetworkblockdevicestoragedeviceattachment/validateurl(_:))
    ///   — pre-flight URL syntactic check without dialing
    ///   the server.
    private static func makeNBDStorageDevice(
        disk: NBDBackedDisk,
        monitors: inout [NBDAttachmentMonitor]
    ) throws -> VZStorageDeviceConfiguration {
        // Pre-flight URL shape — catches malformed NBD URIs
        // with a clear error before `VZVirtualMachine.start`
        // throws something opaque.
        try VZNetworkBlockDeviceStorageDeviceAttachment.validate(disk.url)

        let syncMode: VZDiskSynchronizationMode = switch disk.syncMode {
        case .full: .full
        case .none: .none
        }

        let attachment: VZNetworkBlockDeviceStorageDeviceAttachment
        if disk.timeoutSeconds > 0 {
            attachment = try VZNetworkBlockDeviceStorageDeviceAttachment(
                url: disk.url,
                timeout: disk.timeoutSeconds,
                isForcedReadOnly: disk.forcedReadOnly,
                synchronizationMode: syncMode
            )
        } else {
            // Apple's convenience init picks "optimized
            // defaults" per the header. Use it when the
            // operator didn't override anything so we
            // inherit Apple's tuning on framework upgrades.
            let defaultAttachment = try VZNetworkBlockDeviceStorageDeviceAttachment(
                url: disk.url
            )
            if disk.forcedReadOnly || disk.syncMode != .full {
                // Operator overrode readOnly / syncMode but
                // left timeout at default. Re-build with
                // explicit fields — there's no mutable API
                // on the attachment.
                attachment = try VZNetworkBlockDeviceStorageDeviceAttachment(
                    url: disk.url,
                    timeout: defaultAttachment.timeout,
                    isForcedReadOnly: disk.forcedReadOnly,
                    synchronizationMode: syncMode
                )
            } else {
                attachment = defaultAttachment
            }
        }

        let monitor = NBDAttachmentMonitor(url: disk.url)
        attachment.delegate = monitor
        monitors.append(monitor)

        switch disk.bus {
        case .virtio:
            return VZVirtioBlockDeviceConfiguration(attachment: attachment)
        case .nvme:
            // Same restriction as local NVMe: Apple's
            // `VZNVMExpressControllerDeviceConfiguration`
            // only pairs with `VZGenericPlatformConfiguration`
            // (Linux guests). Error is the same.
            throw StorageConfigurationError.nvmeRequiresLinux
        case .usb:
            // `VZUSBMassStorageDeviceConfiguration` requires
            // a `VZStorageDeviceAttachment` whose concrete
            // type is disk-image-backed; NBD attachments
            // aren't accepted there.
            throw StorageConfigurationError.nbdNotSupportedOnUSB
        }
    }

    /// Builds one `VZStorageDeviceConfiguration` — either a
    /// virtio-blk device or an NVM Express controller —
    /// depending on the spec's `storageController`.
    ///
    /// ## Apple APIs
    ///
    /// - [`VZDiskImageStorageDeviceAttachment(url:readOnly:)`](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment/init(url:readonly:))
    ///   — backing file attachment.
    /// - [`VZVirtioBlockDeviceConfiguration(attachment:)`](https://developer.apple.com/documentation/virtualization/vzvirtioblockdeviceconfiguration/init(attachment:))
    ///   — universal-compatibility block device.
    /// - [`VZNVMExpressControllerDeviceConfiguration(attachment:)`](https://developer.apple.com/documentation/virtualization/vznvmexpresscontrollerdeviceconfiguration/init(attachment:))
    ///   — macOS 14+ NVM Express emulation. **Valid only with
    ///   `VZGenericPlatformConfiguration`** per Apple's
    ///   header — Linux guests only. `.nvme` therefore throws
    ///   ``NetworkConfigurationError`` (reused for config-
    ///   error shape) on Mac platforms until Track H lands.
    ///   WWDC23 session 10007 benchmarks report 15–30 %
    ///   higher sequential I/O than virtio-blk.
    private static func makeStorageDevice(
        url: URL,
        readOnly: Bool,
        controller: StorageController
    ) throws -> VZStorageDeviceConfiguration {
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: url,
            readOnly: readOnly
        )
        switch controller {
        case .virtio:
            return VZVirtioBlockDeviceConfiguration(attachment: attachment)
        case .nvme:
            // Apple's `VZNVMExpressControllerDeviceConfiguration`
            // header explicitly restricts the device to
            // `VZGenericPlatformConfiguration` (Linux guests).
            // Returning one against a Mac platform would be
            // rejected at `validate()` time with a cryptic
            // error; fail loudly here with a message the
            // operator can act on.
            throw StorageConfigurationError.nvmeRequiresLinux
        }
    }

    // MARK: - Private

    private static func makeNetworkDevices(
        for mode: NetworkMode,
        macAddress: MACAddress? = nil
    ) throws -> [VZNetworkDeviceConfiguration] {
        let devices: [VZVirtioNetworkDeviceConfiguration]

        switch mode {
        case .isolated:
            devices = []

        case .bridged(let interface):
            // Cheap host-level pre-check via `getifaddrs(3)` so
            // operators without the `com.apple.vm.networking`
            // entitlement still get a "no such interface" error
            // pointing at the real problem, rather than an empty
            // `VZBridgedNetworkInterface.networkInterfaces` list
            // that only reveals the entitlement issue indirectly.
            //
            // See: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getifaddrs.3.html
            if !hostInterfaceExists(named: interface) {
                Log.config.error(
                    "Bridge interface '\(interface, privacy: .public)' is not present on this host (getifaddrs pre-check)."
                )
                throw NetworkConfigurationError.bridgeInterfaceNotFound(interface)
            }
            let available = VZBridgedNetworkInterface.networkInterfaces
            guard let target = available.first(where: { $0.identifier == interface }) else {
                let names = available.map(\.identifier).joined(separator: ", ")
                Log.config.error("Bridge interface '\(interface, privacy: .public)' not visible to Virtualization. Available: \(names, privacy: .public)")
                throw NetworkConfigurationError.bridgeInterfaceNotFound(interface)
            }
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZBridgedNetworkDeviceAttachment(interface: target)
            devices = [device]

        case .nat:
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZNATNetworkDeviceAttachment()
            devices = [device]
        }

        if let macAddress,
           let mac = VZMACAddress(string: macAddress.rawValue),
           let first = devices.first {
            first.macAddress = mac
        }

        return devices
    }

    /// Walks the host's network interfaces via `getifaddrs(3)` and
    /// reports whether any interface with the given BSD name
    /// (`en0`, `bridge100`, etc.) is present. Errors from
    /// `getifaddrs` are treated as "cannot tell" and return `true`
    /// so we don't block legitimate configurations on a syscall
    /// failure — the caller still falls through to the
    /// `VZBridgedNetworkInterface` check.
    static func hostInterfaceExists(named name: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return true }
        defer { freeifaddrs(head) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let ifname = String(cString: entry.pointee.ifa_name)
            if ifname == name { return true }
            current = entry.pointee.ifa_next
        }
        return false
    }
}

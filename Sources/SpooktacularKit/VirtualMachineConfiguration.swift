import Foundation
import os
import Virtualization

/// Builds `VZVirtualMachineConfiguration` objects from a ``VirtualMachineSpecification``.
///
/// `VirtualMachineConfiguration` translates the product-level specification
/// (CPU count, memory, display count, network mode) into the
/// corresponding Virtualization framework configuration objects.
///
/// The ``applySpec(_:to:)`` method sets CPU, memory, boot loader,
/// graphics, input, network, socket, and entropy devices on a
/// mutable `VZVirtualMachineConfiguration`. Platform configuration
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
/// VirtualMachineConfiguration.applySpec(spec, to: config)
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
    /// and entropy. It does **not** set `platform` or
    /// `storageDevices` — those require bundle-specific artifacts.
    ///
    /// - Parameters:
    ///   - spec: The hardware specification.
    ///   - configuration: The mutable configuration to populate.
    public static func applySpec(
        _ spec: VirtualMachineSpecification,
        to configuration: VZVirtualMachineConfiguration
    ) {
        Log.config.info("Applying spec: \(spec.cpuCount) CPU, \(spec.memorySizeInBytes / (1024*1024*1024)) GB RAM, \(spec.displayCount) display(s)")
        // CPU and memory
        configuration.cpuCount = spec.cpuCount
        configuration.memorySize = spec.memorySizeInBytes

        // Boot loader
        configuration.bootLoader = VZMacOSBootLoader()

        // Graphics
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = (0..<spec.displayCount).map { _ in
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: displayWidth,
                heightInPixels: displayHeight,
                pixelsPerInch: displayPPI
            )
        }
        configuration.graphicsDevices = [graphics]

        // Input
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]

        // Network
        configuration.networkDevices = makeNetworkDevices(
            for: spec.networkMode,
            macAddress: spec.macAddress
        )

        // VirtIO socket — always present for host↔guest communication
        // (IP discovery, graceful shutdown, provisioning signals).
        // Apple docs: https://developer.apple.com/documentation/virtualization/sockets
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Entropy — exposes host randomness to guest for
        // cryptographic operations.
        // Apple docs: https://developer.apple.com/documentation/virtualization/randomization
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon — allows the host to dynamically reclaim
        // unused guest memory. Required for efficient resource use.
        // Apple docs: https://developer.apple.com/documentation/virtualization/vzvirtiotraditionalmemoryballoondeviceconfiguration
        configuration.memoryBalloonDevices = [
            VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        ]

        // Audio — VirtIO sound device with output stream and
        // optional microphone input.
        // Apple docs: https://developer.apple.com/documentation/virtualization/vzvirtiosounddeviceconfiguration
        if spec.audioEnabled {
            let audio = VZVirtioSoundDeviceConfiguration()
            var streams: [VZVirtioSoundDeviceStreamConfiguration] = [
                VZVirtioSoundDeviceOutputStreamConfiguration()
            ]
            if spec.microphoneEnabled {
                streams.append(VZVirtioSoundDeviceInputStreamConfiguration())
            }
            audio.streams = streams
            configuration.audioDevices = [audio]
        }

        // Shared folders — uses VZMultipleDirectoryShare when
        // multiple folders are configured, VZSingleDirectoryShare
        // for a single folder. The macOS guest automount tag makes
        // folders appear automatically in Finder.
        // Apple docs: https://developer.apple.com/documentation/virtualization/shared-directories
        if !spec.sharedFolders.isEmpty {
            let share: VZDirectoryShare
            if spec.sharedFolders.count == 1 {
                let folder = spec.sharedFolders[0]
                share = VZSingleDirectoryShare(
                    directory: VZSharedDirectory(
                        url: URL(fileURLWithPath: folder.hostPath),
                        readOnly: folder.readOnly
                    )
                )
            } else {
                var directories: [String: VZSharedDirectory] = [:]
                for folder in spec.sharedFolders {
                    directories[folder.tag] = VZSharedDirectory(
                        url: URL(fileURLWithPath: folder.hostPath),
                        readOnly: folder.readOnly
                    )
                }
                share = VZMultipleDirectoryShare(directories: directories)
            }
            let device = VZVirtioFileSystemDeviceConfiguration(
                tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
            )
            device.share = share
            configuration.directorySharingDevices = [device]
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
        let platform = VZMacPlatformConfiguration()

        let hardwareModelData = try Data(
            contentsOf: bundle.url.appendingPathComponent("hardware-model.bin")
        )
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            Log.config.error("Invalid hardware model in \(bundle.url.lastPathComponent, privacy: .public)")
            throw VirtualMachineBundleError.invalidConfiguration(url: bundle.url)
        }
        platform.hardwareModel = hardwareModel

        let machineIdentifierData = try Data(
            contentsOf: bundle.url.appendingPathComponent("machine-identifier.bin")
        )
        guard let machineIdentifier = VZMacMachineIdentifier(
            dataRepresentation: machineIdentifierData
        ) else {
            Log.config.error("Invalid machine identifier in \(bundle.url.lastPathComponent, privacy: .public)")
            throw VirtualMachineBundleError.invalidConfiguration(url: bundle.url)
        }
        platform.machineIdentifier = machineIdentifier

        let auxiliaryStorageURL = bundle.url.appendingPathComponent("auxiliary.bin")
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(contentsOf: auxiliaryStorageURL)

        configuration.platform = platform
        Log.config.debug("Platform artifacts loaded for \(bundle.url.lastPathComponent, privacy: .public)")
    }

    /// Applies storage device configuration from a bundle's disk image.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle containing the disk image.
    ///   - configuration: The mutable configuration to populate.
    public static func applyStorage(
        from bundle: VirtualMachineBundle,
        to configuration: VZVirtualMachineConfiguration
    ) throws {
        Log.config.debug("Attaching disk image from \(bundle.url.lastPathComponent, privacy: .public)")
        let diskURL = bundle.url.appendingPathComponent("disk.img")
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL,
            readOnly: false
        )
        let disk = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        configuration.storageDevices = [disk]
    }

    // MARK: - Private

    private static func makeNetworkDevices(
        for mode: NetworkMode,
        macAddress: String? = nil
    ) -> [VZNetworkDeviceConfiguration] {
        let devices: [VZVirtioNetworkDeviceConfiguration]

        switch mode {
        case .isolated:
            devices = []

        case .bridged(let interface):
            let target = VZBridgedNetworkInterface.networkInterfaces
                .first { $0.identifier == interface }
            if let target {
                let device = VZVirtioNetworkDeviceConfiguration()
                device.attachment = VZBridgedNetworkDeviceAttachment(interface: target)
                devices = [device]
            } else {
                devices = [makeNATDevice()]
            }

        case .hostOnly:
            // Host-only requires a user-space virtual switch via
            // VZFileHandleNetworkDeviceAttachment. Fall back to
            // NAT until the file-handle networking subsystem is
            // implemented.
            Log.network.warning("Host-only networking not yet implemented; falling back to NAT")
            devices = [makeNATDevice()]

        case .nat:
            devices = [makeNATDevice()]
        }

        if let macString = macAddress,
           let mac = VZMACAddress(string: macString),
           let first = devices.first {
            first.macAddress = mac
        }

        return devices
    }

    private static func makeNATDevice() -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return device
    }
}

import Foundation
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
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.graphicsDevices = [makeGraphics(displayCount: spec.displayCount)]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        configuration.networkDevices = try makeNetworkDevices(
            for: spec.networkMode, macAddress: spec.macAddress
        )
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [
            VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        ]

        if spec.audioEnabled {
            configuration.audioDevices = [makeAudio(microphone: spec.microphoneEnabled)]
        }

        if !spec.sharedFolders.isEmpty {
            configuration.directorySharingDevices = makeSharing(spec.sharedFolders)
        }

        if spec.clipboardSharingEnabled {
            Log.config.warning("Clipboard sharing is only supported for Linux guests. macOS guests do not support clipboard synchronization through the Virtualization framework.")
        }
    }

    private static func makeGraphics(
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

    private static func makeAudio(
        microphone: Bool
    ) -> VZVirtioSoundDeviceConfiguration {
        let audio = VZVirtioSoundDeviceConfiguration()
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = [
            VZVirtioSoundDeviceOutputStreamConfiguration()
        ]
        if microphone {
            streams.append(VZVirtioSoundDeviceInputStreamConfiguration())
        }
        audio.streams = streams
        return audio
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
                    url: URL(fileURLWithPath: folder.hostPath),
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
                    url: URL(fileURLWithPath: folder.hostPath),
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
        let diskURL = bundle.url.appendingPathComponent(VirtualMachineBundle.diskImageFileName)
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
    ) throws -> [VZNetworkDeviceConfiguration] {
        let devices: [VZVirtioNetworkDeviceConfiguration]

        switch mode {
        case .isolated:
            devices = []

        case .bridged(let interface):
            let available = VZBridgedNetworkInterface.networkInterfaces
            guard let target = available.first(where: { $0.identifier == interface }) else {
                let names = available.map(\.identifier).joined(separator: ", ")
                Log.config.error("Bridge interface '\(interface, privacy: .public)' not found. Available: \(names, privacy: .public)")
                throw NetworkConfigurationError.bridgeInterfaceNotFound(interface)
            }
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZBridgedNetworkDeviceAttachment(interface: target)
            devices = [device]

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

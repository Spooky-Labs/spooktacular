import Foundation
import Virtualization

/// Builds `VZVirtualMachineConfiguration` objects from a ``VMSpec``.
///
/// `VMConfiguration` translates the product-level specification
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
/// VMConfiguration.applySpec(spec, to: config)
///
/// // Apply platform and storage from bundle artifacts.
/// config.platform = platform
/// config.storageDevices = [diskDevice]
///
/// try config.validate()
/// ```
public enum VMConfiguration {

    /// Default display resolution for virtual screens.
    private static let displayWidth = 1920
    private static let displayHeight = 1200
    private static let displayPPI = 80

    /// Applies a ``VMSpec`` to a `VZVirtualMachineConfiguration`.
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
        _ spec: VMSpec,
        to configuration: VZVirtualMachineConfiguration
    ) {
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
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Entropy — exposes host randomness to guest for
        // cryptographic operations.
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Audio
        if spec.audioEnabled {
            let audio = VZVirtioSoundDeviceConfiguration()
            let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
            audio.streams = [outputStream]
            if spec.microphoneEnabled {
                let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
                audio.streams.append(inputStream)
            }
            configuration.audioDevices = [audio]
        }

        // Shared folders
        var directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = []
        for (index, folder) in spec.sharedFolders.enumerated() {
            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(
                    url: URL(fileURLWithPath: folder.hostPath),
                    readOnly: folder.readOnly
                )
            )
            let tag = index == 0
                ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
                : folder.tag
            let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            device.share = share
            directorySharingDevices.append(device)
        }
        if !directorySharingDevices.isEmpty {
            configuration.directorySharingDevices = directorySharingDevices
        }
    }

    /// Applies platform-specific configuration from bundle artifacts.
    ///
    /// Reads the hardware model, machine identifier, and auxiliary
    /// storage files from a ``VMBundle`` and sets them on the
    /// configuration's `platform` property.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle containing platform artifact files.
    ///   - configuration: The mutable configuration to populate.
    /// - Throws: ``VMBundleError/invalidConfiguration(url:)`` if
    ///   the platform artifacts cannot be loaded.
    public static func applyPlatform(
        from bundle: VMBundle,
        to configuration: VZVirtualMachineConfiguration
    ) throws {
        let platform = VZMacPlatformConfiguration()

        let hwModelData = try Data(
            contentsOf: bundle.url.appendingPathComponent("hardware-model.bin")
        )
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hwModelData) else {
            throw VMBundleError.invalidConfiguration(url: bundle.url)
        }
        platform.hardwareModel = hardwareModel

        let midData = try Data(
            contentsOf: bundle.url.appendingPathComponent("machine-identifier.bin")
        )
        guard let machineIdentifier = VZMacMachineIdentifier(
            dataRepresentation: midData
        ) else {
            throw VMBundleError.invalidConfiguration(url: bundle.url)
        }
        platform.machineIdentifier = machineIdentifier

        let auxURL = bundle.url.appendingPathComponent("auxiliary.bin")
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(contentsOf: auxURL)

        configuration.platform = platform
    }

    /// Applies storage device configuration from a bundle's disk image.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle containing the disk image.
    ///   - configuration: The mutable configuration to populate.
    public static func applyStorage(
        from bundle: VMBundle,
        to configuration: VZVirtualMachineConfiguration
    ) throws {
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
        case .nat:
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZNATNetworkDeviceAttachment()
            devices = [device]

        case .bridged(let interface):
            let interfaces = VZBridgedNetworkInterface.networkInterfaces
            guard let target = interfaces.first(where: {
                $0.identifier == interface
            }) else {
                // Fall back to NAT if the requested interface
                // is not found. A warning should be logged by
                // the caller.
                let device = VZVirtioNetworkDeviceConfiguration()
                device.attachment = VZNATNetworkDeviceAttachment()
                devices = [device]
                break
            }
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZBridgedNetworkDeviceAttachment(interface: target)
            devices = [device]

        case .isolated:
            devices = []

        case .hostOnly:
            // Host-only requires a user-space virtual switch via
            // VZFileHandleNetworkDeviceAttachment. For now, fall
            // back to NAT — the full implementation requires the
            // file-handle networking subsystem.
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZNATNetworkDeviceAttachment()
            devices = [device]
        }

        // Apply custom MAC address to the first network device
        // when specified.
        if let macString = macAddress,
           let mac = VZMACAddress(string: macString),
           let first = devices.first {
            first.macAddress = mac
        }

        return devices
    }
}

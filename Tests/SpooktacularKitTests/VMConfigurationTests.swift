import Testing
import Foundation
@preconcurrency import Virtualization
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("VirtualMachineConfiguration")
struct VirtualMachineConfigurationTests {

    @Test("Sets CPU count from spec")
    func cpuCount() throws {
        let spec = VirtualMachineSpecification(cpuCount: 8)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.cpuCount == 8)
    }

    @Test("Enforces minimum CPU count")
    func minimumCPU() throws {
        let spec = VirtualMachineSpecification(cpuCount: 2)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.cpuCount == 4)
    }

    @Test("Sets memory size from spec")
    func memorySize() throws {
        let memory: UInt64 = 16 * 1024 * 1024 * 1024
        let spec = VirtualMachineSpecification(memorySizeInBytes: memory)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.memorySize == memory)
    }

    @Test("Creates one graphics device with correct display count")
    func singleDisplay() throws {
        let spec = VirtualMachineSpecification(displayCount: 1)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.graphicsDevices.count == 1)
        let macGraphics = try #require(
            config.graphicsDevices.first as? VZMacGraphicsDeviceConfiguration
        )
        #expect(macGraphics.displays.count == 1)
    }

    @Test("Creates two displays when requested")
    func dualDisplay() throws {
        let spec = VirtualMachineSpecification(displayCount: 2)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        let macGraphics = try #require(
            config.graphicsDevices.first as? VZMacGraphicsDeviceConfiguration
        )
        #expect(macGraphics.displays.count == 2)
    }

    @Test("Configures NAT networking")
    func natNetwork() throws {
        let spec = VirtualMachineSpecification(networkMode: .nat)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.networkDevices.count == 1)
        let virtioNet = try #require(
            config.networkDevices.first as? VZVirtioNetworkDeviceConfiguration
        )
        #expect(virtioNet.attachment is VZNATNetworkDeviceAttachment)
    }

    @Test("Configures isolated networking (no devices)")
    func isolatedNetwork() throws {
        let spec = VirtualMachineSpecification(networkMode: .isolated)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.networkDevices.isEmpty)
    }

    @Test("Bridged mode throws when interface is not found")
    func bridgedThrows() throws {
        let spec = VirtualMachineSpecification(networkMode: .bridged(interface: "nonexistent99"))
        let config = VZVirtualMachineConfiguration()

        #expect(throws: NetworkConfigurationError.bridgeInterfaceNotFound("nonexistent99")) {
            try VirtualMachineConfiguration.applySpec(spec, to: config)
        }
    }

    @Test("Sets macOS boot loader")
    func bootLoader() throws {
        let spec = VirtualMachineSpecification()
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.bootLoader is VZMacOSBootLoader)
    }

    @Test("Adds keyboard and trackpad")
    func inputDevices() throws {
        let spec = VirtualMachineSpecification()
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.keyboards.count == 1)
        #expect(config.keyboards.first is VZMacKeyboardConfiguration)
        #expect(config.pointingDevices.count == 1)
        #expect(config.pointingDevices.first is VZMacTrackpadConfiguration)
    }

    @Test("Always includes a VirtIO socket device")
    func socketDevice() throws {
        let spec = VirtualMachineSpecification()
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        let hasSocket = config.socketDevices.contains {
            $0 is VZVirtioSocketDeviceConfiguration
        }
        #expect(hasSocket, "VirtIO socket is required for host↔guest communication")
    }

    @Test("Always includes an entropy device")
    func entropyDevice() throws {
        let spec = VirtualMachineSpecification()
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(!config.entropyDevices.isEmpty)
    }

    @Test("Always includes a memory balloon device")
    func memoryBalloon() throws {
        let spec = VirtualMachineSpecification()
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(
            !config.memoryBalloonDevices.isEmpty,
            "Memory balloon is required for dynamic memory management"
        )
    }

    @Test("Single shared folder uses VZSingleDirectoryShare")
    func singleSharedFolder() throws {
        let spec = VirtualMachineSpecification(sharedFolders: [
            SharedFolder(hostPath: "/tmp", tag: "single"),
        ])
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        let device = try #require(
            config.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration
        )
        #expect(device.share is VZSingleDirectoryShare)
    }

    @Test("Configures audio output when audioEnabled")
    func audioOutput() throws {
        let spec = VirtualMachineSpecification(audioEnabled: true)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.audioDevices.count == 1)
        let sound = try #require(
            config.audioDevices.first as? VZVirtioSoundDeviceConfiguration
        )
        let hasOutput = sound.streams.contains { $0 is VZVirtioSoundDeviceOutputStreamConfiguration }
        #expect(hasOutput, "Audio device must include an output stream")
    }

    @Test("Includes microphone input when microphoneEnabled")
    func microphoneInput() throws {
        let spec = VirtualMachineSpecification(audioEnabled: true, microphoneEnabled: true)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        let sound = try #require(
            config.audioDevices.first as? VZVirtioSoundDeviceConfiguration
        )
        let hasInput = sound.streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration }
        #expect(hasInput, "Audio device must include an input stream when microphone is enabled")
    }

    @Test("No audio devices when audioEnabled is false")
    func noAudio() throws {
        let spec = VirtualMachineSpecification(audioEnabled: false)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        #expect(config.audioDevices.isEmpty)
    }

    @Test("Multiple shared folders create one device per folder with unique tags")
    func sharedFolders() throws {
        let spec = VirtualMachineSpecification(sharedFolders: [
            SharedFolder(hostPath: "/tmp", tag: "first"),
            SharedFolder(hostPath: "/var", tag: "second", readOnly: true),
        ])
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        // Each folder gets its own VZVirtioFileSystemDeviceConfiguration
        // with a unique tag so the guest can mount them individually.
        #expect(config.directorySharingDevices.count == 2)

        let devices = config.directorySharingDevices
            .compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
        #expect(devices.count == 2)
        #expect(devices[0].tag == "first")
        #expect(devices[1].tag == "second")
    }

    @Test("First shared folder uses macOSGuestAutomountTag")
    func firstFolderAutomountTag() throws {
        let spec = VirtualMachineSpecification(sharedFolders: [
            SharedFolder(hostPath: "/tmp", tag: "ignored"),
        ])
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        let device = try #require(
            config.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration
        )
        #expect(
            device.tag == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag,
            "First shared folder must use the macOS guest automount tag"
        )
    }

    @Test("Custom MAC address is ignored in isolated mode")
    func macAddressIgnoredInIsolated() throws {
        let mac = MACAddress("aa:bb:cc:dd:ee:ff")!
        let spec = VirtualMachineSpecification(networkMode: .isolated, macAddress: mac)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)
        #expect(config.networkDevices.isEmpty)
    }

    @Test("Sets custom MAC address when specified")
    func customMACAddress() throws {
        let macString = "AA:BB:CC:DD:EE:FF"
        let mac = MACAddress(macString)!
        let spec = VirtualMachineSpecification(macAddress: mac)
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(spec, to: config)

        let virtioNet = try #require(
            config.networkDevices.first as? VZVirtioNetworkDeviceConfiguration
        )
        let expected = try #require(VZMACAddress(string: macString))
        #expect(
            virtioNet.macAddress == expected,
            "Network device must use the specified MAC address"
        )
    }
}

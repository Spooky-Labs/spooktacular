import Testing
import Foundation
import Virtualization
@testable import SpooktacularKit

@Suite("VMConfiguration")
struct VMConfigurationTests {

    @Test("Sets CPU count from spec")
    func cpuCount() {
        let spec = VMSpec(cpuCount: 8)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.cpuCount == 8)
    }

    @Test("Enforces minimum CPU count")
    func minimumCPU() {
        let spec = VMSpec(cpuCount: 2)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.cpuCount == 4)
    }

    @Test("Sets memory size from spec")
    func memorySize() {
        let memory: UInt64 = 16 * 1024 * 1024 * 1024
        let spec = VMSpec(memorySizeInBytes: memory)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.memorySize == memory)
    }

    @Test("Creates one graphics device with correct display count")
    func singleDisplay() throws {
        let spec = VMSpec(displayCount: 1)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.graphicsDevices.count == 1)
        let macGraphics = try #require(
            config.graphicsDevices.first as? VZMacGraphicsDeviceConfiguration
        )
        #expect(macGraphics.displays.count == 1)
    }

    @Test("Creates two displays when requested")
    func dualDisplay() throws {
        let spec = VMSpec(displayCount: 2)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        let macGraphics = try #require(
            config.graphicsDevices.first as? VZMacGraphicsDeviceConfiguration
        )
        #expect(macGraphics.displays.count == 2)
    }

    @Test("Configures NAT networking")
    func natNetwork() throws {
        let spec = VMSpec(networkMode: .nat)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.networkDevices.count == 1)
        let virtioNet = try #require(
            config.networkDevices.first as? VZVirtioNetworkDeviceConfiguration
        )
        #expect(virtioNet.attachment is VZNATNetworkDeviceAttachment)
    }

    @Test("Configures isolated networking (no devices)")
    func isolatedNetwork() {
        let spec = VMSpec(networkMode: .isolated)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.networkDevices.isEmpty)
    }

    @Test("Bridged mode falls back to NAT when interface is not found")
    func bridgedFallback() throws {
        let spec = VMSpec(networkMode: .bridged(interface: "nonexistent99"))
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        // Should have one device (NAT fallback), not crash.
        #expect(config.networkDevices.count == 1)
        let virtioNet = try #require(
            config.networkDevices.first as? VZVirtioNetworkDeviceConfiguration
        )
        #expect(
            virtioNet.attachment is VZNATNetworkDeviceAttachment,
            "Bridged with missing interface should fall back to NAT"
        )
    }

    @Test("Host-only mode currently produces a NAT device")
    func hostOnlyFallback() throws {
        let spec = VMSpec(networkMode: .hostOnly)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.networkDevices.count == 1)
        let virtioNet = try #require(
            config.networkDevices.first as? VZVirtioNetworkDeviceConfiguration
        )
        #expect(
            virtioNet.attachment is VZNATNetworkDeviceAttachment,
            "Host-only currently falls back to NAT"
        )
    }

    @Test("Sets macOS boot loader")
    func bootLoader() {
        let spec = VMSpec()
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.bootLoader is VZMacOSBootLoader)
    }

    @Test("Adds keyboard and trackpad")
    func inputDevices() {
        let spec = VMSpec()
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.keyboards.count == 1)
        #expect(config.keyboards.first is VZMacKeyboardConfiguration)
        #expect(config.pointingDevices.count == 1)
        #expect(config.pointingDevices.first is VZMacTrackpadConfiguration)
    }

    @Test("Always includes a VirtIO socket device")
    func socketDevice() {
        let spec = VMSpec()
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        let hasSocket = config.socketDevices.contains {
            $0 is VZVirtioSocketDeviceConfiguration
        }
        #expect(hasSocket, "VirtIO socket is required for host↔guest communication")
    }

    @Test("Always includes an entropy device")
    func entropyDevice() {
        let spec = VMSpec()
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(!config.entropyDevices.isEmpty)
    }

    @Test("Configures audio output when audioEnabled")
    func audioOutput() throws {
        let spec = VMSpec(audioEnabled: true)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.audioDevices.count == 1)
        let sound = try #require(
            config.audioDevices.first as? VZVirtioSoundDeviceConfiguration
        )
        let hasOutput = sound.streams.contains { $0 is VZVirtioSoundDeviceOutputStreamConfiguration }
        #expect(hasOutput, "Audio device must include an output stream")
    }

    @Test("Includes microphone input when microphoneEnabled")
    func microphoneInput() throws {
        let spec = VMSpec(audioEnabled: true, microphoneEnabled: true)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        let sound = try #require(
            config.audioDevices.first as? VZVirtioSoundDeviceConfiguration
        )
        let hasInput = sound.streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration }
        #expect(hasInput, "Audio device must include an input stream when microphone is enabled")
    }

    @Test("No audio devices when audioEnabled is false")
    func noAudio() {
        let spec = VMSpec(audioEnabled: false)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.audioDevices.isEmpty)
    }

    @Test("Configures shared folders as directory sharing devices")
    func sharedFolders() {
        let spec = VMSpec(sharedFolders: [
            SharedFolder(hostPath: "/tmp", tag: "first"),
            SharedFolder(hostPath: "/var", tag: "second", readOnly: true),
        ])
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        #expect(config.directorySharingDevices.count == 2)
    }

    @Test("First shared folder uses macOSGuestAutomountTag")
    func firstFolderAutomountTag() throws {
        let spec = VMSpec(sharedFolders: [
            SharedFolder(hostPath: "/tmp", tag: "ignored"),
        ])
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

        let device = try #require(
            config.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration
        )
        #expect(
            device.tag == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag,
            "First shared folder must use the macOS guest automount tag"
        )
    }

    @Test("Sets custom MAC address when specified")
    func customMACAddress() throws {
        let macString = "AA:BB:CC:DD:EE:FF"
        let spec = VMSpec(macAddress: macString)
        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(spec, to: config)

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

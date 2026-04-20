import Testing
import Foundation
@preconcurrency import Virtualization
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("VirtualMachineConfiguration", .tags(.lifecycle))
struct VirtualMachineConfigurationTests {

    // MARK: - CPU and Memory

    @Suite("CPU and memory", .tags(.lifecycle))
    struct CPUMemoryTests {

        @Test("Sets CPU count from spec")
        func cpuCount() throws {
            let spec = VirtualMachineSpecification(cpuCount: 8)
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(spec, to: config)
            #expect(config.cpuCount == 8)
        }

        @Test("Enforces minimum CPU count of 4")
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
    }

    // MARK: - Graphics

    @Suite("Graphics", .tags(.lifecycle))
    struct GraphicsTests {

        @Test(
            "Creates correct number of displays",
            arguments: [(1, 1), (2, 2)]
        )
        func displayCount(requested: Int, expected: Int) throws {
            let spec = VirtualMachineSpecification(displayCount: requested)
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(spec, to: config)

            let macGraphics = try #require(
                config.graphicsDevices.first as? VZMacGraphicsDeviceConfiguration
            )
            #expect(macGraphics.displays.count == expected)
        }
    }

    // MARK: - Networking

    @Suite("Networking", .tags(.lifecycle))
    struct NetworkingTests {

        @Test("Configures NAT networking")
        func natNetwork() throws {
            let spec = VirtualMachineSpecification(networkMode: .nat)
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(spec, to: config)

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

        @Test("Sets custom MAC address when specified")
        func customMACAddress() throws {
            let macString = "AA:BB:CC:DD:EE:FF"
            let mac = try #require(MACAddress(macString))
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

        @Test("Custom MAC address is ignored in isolated mode")
        func macAddressIgnoredInIsolated() throws {
            let mac = try #require(MACAddress("aa:bb:cc:dd:ee:ff"))
            let spec = VirtualMachineSpecification(networkMode: .isolated, macAddress: mac)
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(spec, to: config)
            #expect(config.networkDevices.isEmpty)
        }
    }

    // MARK: - System Devices

    @Suite("System devices", .tags(.lifecycle))
    struct SystemDeviceTests {

        @Test("Sets macOS boot loader")
        func bootLoader() throws {
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(VirtualMachineSpecification(), to: config)
            #expect(config.bootLoader is VZMacOSBootLoader)
        }

        @Test("Adds keyboard and trackpad")
        func inputDevices() throws {
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(VirtualMachineSpecification(), to: config)

            #expect(config.keyboards.first is VZMacKeyboardConfiguration)
            #expect(config.pointingDevices.first is VZMacTrackpadConfiguration)
        }

        @Test("Always includes a VirtIO socket device")
        func socketDevice() throws {
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(VirtualMachineSpecification(), to: config)

            let hasSocket = config.socketDevices.contains { $0 is VZVirtioSocketDeviceConfiguration }
            #expect(hasSocket, "VirtIO socket is required for host-guest communication")
        }

        @Test("Always includes an entropy device")
        func entropyDevice() throws {
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(VirtualMachineSpecification(), to: config)
            #expect(!config.entropyDevices.isEmpty)
        }

        @Test("Always includes a memory balloon device")
        func memoryBalloon() throws {
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(VirtualMachineSpecification(), to: config)
            #expect(
                !config.memoryBalloonDevices.isEmpty,
                "Memory balloon is required for dynamic memory management"
            )
        }
    }

    // MARK: - Audio

    @Suite("Audio", .tags(.lifecycle))
    struct AudioTests {

        @Test("Configures audio output when audioEnabled")
        func audioOutput() throws {
            let spec = VirtualMachineSpecification(audioEnabled: true)
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(spec, to: config)

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
    }

    // MARK: - Shared Folders

    @Suite("Shared folders", .tags(.lifecycle))
    struct SharedFoldersTests {

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
    }

    // MARK: - Guest OS (Track H)

    /// Asserts that `applySpec` emits the right Apple-framework
    /// device classes for each guest-OS branch. These tests
    /// pin the contract between our `GuestOS` enum and the
    /// concrete `VZ*` graph so a future refactor can't
    /// silently flip Linux VMs to `VZMacOSBootLoader` (which
    /// would fail `configuration.validate()` at VM start).
    @Suite("Guest OS branching", .tags(.lifecycle))
    struct GuestOSTests {

        @Test("macOS guest gets VZMacOSBootLoader + Mac-specific peripherals")
        func macOSBranch() throws {
            let spec = VirtualMachineSpecification(guestOS: .macOS)
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(spec, to: config)

            #expect(config.bootLoader is VZMacOSBootLoader)
            #expect(config.graphicsDevices.first is VZMacGraphicsDeviceConfiguration)
            #expect(config.keyboards.first is VZMacKeyboardConfiguration)
            #expect(config.pointingDevices.first is VZMacTrackpadConfiguration)
            // macOS path doesn't install a USB controller —
            // Mac peripherals don't go through XHCI.
            #expect(config.usbControllers.isEmpty)
        }

        @Test("Linux guest gets VZEFIBootLoader + USB peripherals + explicit XHCI controller")
        func linuxBranch() throws {
            let spec = VirtualMachineSpecification(cpuCount: 1, guestOS: .linux)
            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(spec, to: config)

            #expect(config.bootLoader is VZEFIBootLoader)
            #expect(config.graphicsDevices.first is VZVirtioGraphicsDeviceConfiguration)
            #expect(config.keyboards.first is VZUSBKeyboardConfiguration)
            #expect(config.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
            // `applySpec` installs a VZXHCIControllerConfiguration
            // for every Linux guest.  Apple's
            // `VZUSBMassStorageDeviceConfiguration` docs are
            // explicit: "Be sure to add a
            // VZUSBControllerConfiguration to your configuration
            // to provide a USB controller."  Without it, the
            // installer ISO lands in `storageDevices` but has
            // no bus to terminate on, EFI can't enumerate it,
            // and the VM boots to a black screen.
            #expect(config.usbControllers.count == 1)
            #expect(config.usbControllers.first is VZXHCIControllerConfiguration)
        }

        @Test("Linux guest honours a 1-CPU spec (macOS floor of 4 does not apply)")
        func linuxHonoursSingleCPU() {
            let spec = VirtualMachineSpecification(cpuCount: 1, guestOS: .linux)
            #expect(spec.cpuCount == 1)
        }

        @Test("macOS guest still clamps CPU to 4")
        func macOSStillClamps() {
            let spec = VirtualMachineSpecification(cpuCount: 1, guestOS: .macOS)
            #expect(spec.cpuCount == 4)
        }

        @Test("applyPlatform on a Linux bundle installs VZGenericPlatformConfiguration + EFI NVRAM")
        func linuxApplyPlatformLoadsNVRAM() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("linux.vm")
            let bundle = try VirtualMachineBundle.create(
                at: bundleURL,
                spec: VirtualMachineSpecification(cpuCount: 1, guestOS: .linux)
            )

            let config = VZVirtualMachineConfiguration()
            try VirtualMachineConfiguration.applySpec(bundle.spec, to: config)
            try VirtualMachineConfiguration.applyPlatform(from: bundle, to: config)

            #expect(config.platform is VZGenericPlatformConfiguration)

            let efiLoader = try #require(config.bootLoader as? VZEFIBootLoader)
            let varStore = try #require(efiLoader.variableStore)
            #expect(varStore.url == bundle.efiVariableStoreURL)
        }

        // NOTE: applyStorage isn't unit-tested here because
        // it opens `disk.img` via
        // `VZDiskImageStorageDeviceAttachment`, which
        // validates the file as a RAW disk image up front.
        // Scratch files fail with `NSPOSIXErrorDomain 45
        // (ENOTSUP)` — VZ's `F_PUNCHHOLE`/`F_PREALLOCATE`
        // fcntls don't work on test temp files. Integration
        // coverage for the XHCI-merge contract happens via
        // Track G's USB-disk tests which ship a genuine
        // RAW image fixture.

        @Test("Pre-Track-H bundles without guestOS key decode as macOS")
        func backwardCompatibleDecode() throws {
            // Minimal pre-Track-H config.json shape: no guestOS
            // field. `decodeIfPresent` in init(from:) should
            // substitute .macOS.
            let json = """
            {
              "cpuCount": 8,
              "memorySizeInBytes": 8589934592,
              "diskSizeInBytes": 68719476736,
              "displayCount": 1,
              "networkMode": { "nat": {} },
              "audioEnabled": true,
              "microphoneEnabled": false,
              "sharedFolders": [],
              "autoResizeDisplay": true,
              "clipboardSharingEnabled": true
            }
            """.data(using: .utf8)!
            let spec = try JSONDecoder().decode(VirtualMachineSpecification.self, from: json)
            #expect(spec.guestOS == .macOS)
            #expect(spec.cpuCount == 8)
        }
    }
}

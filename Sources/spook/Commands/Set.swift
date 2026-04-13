import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Modifies the configuration of a stopped virtual machine.
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Modify a VM's configuration.",
            discussion: """
                Changes the hardware specification of an existing VM. \
                The VM must be stopped before modifying its configuration. \
                Only the options you specify are changed — all others \
                remain at their current values.

                EXAMPLES:
                  spook set my-vm --cpu 8 --memory 16
                  spook set runner --network nat --audio
                  spook set dev --displays 2 --disable-audio
                  spook set ci --network bridged:en0
                """
        )

        @Argument(help: "Name of the VM to modify.")
        var name: String

        @Option(help: "Number of CPU cores. Minimum 4 for macOS VMs.")
        var cpu: Int?

        @Option(help: "Memory in GB.")
        var memory: Int?

        @Option(help: "Number of virtual displays (1 or 2).")
        var displays: Int?

        @Option(
            help: """
                Network mode: nat, isolated, or bridged:<interface>. \
                Example: --network bridged:en0
                """
        )
        var network: NetworkMode?

        @Flag(
            inversion: .prefixedEnableDisable,
            help: "Enable or disable audio output."
        )
        var audio: Bool?

        @Flag(
            inversion: .prefixedEnableDisable,
            help: "Enable or disable microphone passthrough."
        )
        var microphone: Bool?

        @Flag(
            inversion: .prefixedEnableDisable,
            help: "Enable or disable automatic display resize."
        )
        var autoResize: Bool?

        func run() async throws {
            let bundleURL = try Paths.requireBundle(for: name)

            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            let oldSpec = bundle.spec

            let newSpec = oldSpec.with(
                cpuCount: cpu,
                memorySizeInBytes: memory.map { UInt64($0) * 1024 * 1024 * 1024 },
                displayCount: displays,
                networkMode: network,
                audioEnabled: audio,
                microphoneEnabled: microphone,
                autoResizeDisplay: autoResize
            )

            let data = try VirtualMachineBundle.encoder.encode(newSpec)
            try data.write(to: bundleURL.appendingPathComponent(VirtualMachineBundle.configFileName))

            print("Updated VM '\(name)' configuration.")

            if let cpuCount = cpu { print("  CPU: \(max(cpuCount, VirtualMachineSpecification.minimumCPUCount)) cores") }
            if let memorySize = memory { print("  Memory: \(memorySize) GB") }
            if let displayCount = displays { print("  Displays: \(min(max(displayCount, 1), 2))") }
            if let networkMode = network { print("  Network: \(networkMode)") }
            if let audioEnabled = audio { print("  Audio: \(audioEnabled ? "enabled" : "disabled")") }
            if let microphoneEnabled = microphone { print("  Microphone: \(microphoneEnabled ? "enabled" : "disabled")") }
            if let autoResizeEnabled = autoResize { print("  Auto-resize: \(autoResizeEnabled ? "enabled" : "disabled")") }
        }
    }
}

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
                  spook set dev --displays 2 --no-audio
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
                Network mode: nat, isolated, host-only, or bridged:<interface>. \
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
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found. Run 'spook list' to see available VMs.")
                throw ExitCode.failure
            }

            let bundle = try VMBundle.load(from: bundleURL)
            let oldSpec = bundle.spec

            let newSpec = VMSpec(
                cpuCount: cpu ?? oldSpec.cpuCount,
                memorySizeInBytes: memory.map { UInt64($0) * 1024 * 1024 * 1024 }
                    ?? oldSpec.memorySizeInBytes,
                diskSizeInBytes: oldSpec.diskSizeInBytes,
                displayCount: displays ?? oldSpec.displayCount,
                networkMode: network ?? oldSpec.networkMode,
                audioEnabled: audio ?? oldSpec.audioEnabled,
                microphoneEnabled: microphone ?? oldSpec.microphoneEnabled,
                sharedFolders: oldSpec.sharedFolders,
                macAddress: oldSpec.macAddress,
                autoResizeDisplay: autoResize ?? oldSpec.autoResizeDisplay,
                clipboardSharingEnabled: oldSpec.clipboardSharingEnabled
            )

            let data = try VMBundle.encoder.encode(newSpec)
            try data.write(to: bundleURL.appendingPathComponent(VMBundle.configFileName))

            print("Updated VM '\(name)' configuration.")

            if let c = cpu { print("  CPU: \(max(c, VMSpec.minimumCPUCount)) cores") }
            if let m = memory { print("  Memory: \(m) GB") }
            if let d = displays { print("  Displays: \(min(max(d, 1), 2))") }
            if let n = network { print("  Network: \(n)") }
            if let a = audio { print("  Audio: \(a ? "enabled" : "disabled")") }
            if let m = microphone { print("  Microphone: \(m ? "enabled" : "disabled")") }
            if let r = autoResize { print("  Auto-resize: \(r ? "enabled" : "disabled")") }
        }
    }
}

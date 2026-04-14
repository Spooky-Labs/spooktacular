import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Displays the configuration of a virtual machine.
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a VM's configuration.",
            discussion: """
                Displays the current hardware specification and metadata \
                for a VM. By default, the output is a human-readable \
                table. Use --json for machine-parsable output or \
                --field to extract a single value.

                EXAMPLES:
                  spook get my-vm
                  spook get my-vm --json
                  spook get my-vm --field cpu
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        @Flag(help: "Output as JSON.")
        var json: Bool = false

        @Option(
            help: """
                Print only the value of a specific field. \
                Available: cpu, memory, disk, displays, network, \
                audio, microphone, id, setup.
                """
        )
        var field: String?

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            let spec = bundle.spec
            let metadata = bundle.metadata

            if let field {
                try printField(field, spec: spec, metadata: metadata)
                return
            }

            if json {
                let data = try VirtualMachineBundle.encoder.encode(spec)
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }

            printStyledConfig(name: name, spec: spec, metadata: metadata, bundle: bundle)
        }

        private func printStyledConfig(
            name: String,
            spec: VirtualMachineSpecification,
            metadata: VirtualMachineMetadata,
            bundle: VirtualMachineBundle
        ) {
            print()
            print("  \(Style.bold(name))")
            print("  \(metadata.setupCompleted ? Style.green("● ready") : Style.yellow("○ setup pending"))")
            print()

            Style.header("  ⬡ Hardware")
            Style.field("CPU", "\(spec.cpuCount) cores")
            Style.field("Memory", "\(spec.memorySizeInGigabytes) GB")
            Style.field("Disk", "\(spec.diskSizeInGigabytes) GB" + Style.dim(" (APFS sparse)"))

            Style.header("  ◻ Display")
            Style.field("Monitors", "\(spec.displayCount)")
            Style.field("Auto-resize", spec.autoResizeDisplay
                        ? Style.green("enabled") : Style.dim("disabled"))

            Style.header("  ⬡ Network")
            Style.field("Mode", spec.networkMode.serialized)
            Style.field("MAC address", Style.dim(spec.macAddress?.rawValue ?? "auto"))

            Style.header("  ♪ Audio")
            Style.field("Speaker", spec.audioEnabled
                        ? Style.green("enabled") : Style.dim("disabled"))
            Style.field("Microphone", spec.microphoneEnabled
                        ? Style.green("enabled") : Style.dim("disabled"))
            Style.field("Clipboard", spec.clipboardSharingEnabled
                        ? Style.green("enabled") : Style.dim("disabled"))

            Style.header("  ⤢ Shared Folders")
            if spec.sharedFolders.isEmpty {
                Style.field("", Style.dim("none"))
            } else {
                for folder in spec.sharedFolders {
                    let perms = folder.readOnly
                        ? Style.yellow("ro") : Style.green("rw")
                    Style.field(
                        folder.tag,
                        "\(Style.dim(folder.hostPath)) [\(perms)]"
                    )
                }
            }

            Style.header("  ◈ Identity")
            Style.field("ID", Style.dim(metadata.id.uuidString))
            Style.field("Created", Style.dim(
                metadata.createdAt.formatted(
                    .dateTime.month().day().year().hour().minute()
                )
            ))
            Style.field("Bundle", Style.dim(bundle.url.path))

            print()
        }

        private func printField(
            _ field: String,
            spec: VirtualMachineSpecification,
            metadata: VirtualMachineMetadata
        ) throws {
            switch field {
            case "cpu": print(spec.cpuCount)
            case "memory": print(spec.memorySizeInGigabytes)
            case "disk": print(spec.diskSizeInGigabytes)
            case "displays": print(spec.displayCount)
            case "network": print(spec.networkMode.serialized)
            case "audio": print(spec.audioEnabled)
            case "microphone": print(spec.microphoneEnabled)
            case "id": print(metadata.id.uuidString)
            case "setup": print(metadata.setupCompleted)
            default:
                print(Style.error("✗ Unknown field '\(field)'."))
                print(Style.dim("  Available: cpu, memory, disk, displays, network, audio, microphone, id, setup"))
                throw ExitCode.failure
            }
        }

    }
}

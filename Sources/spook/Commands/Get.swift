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
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print(Style.error("✗ VM '\(name)' not found.") + Style.dim(" Run 'spook list' to see available VMs."))
                throw ExitCode.failure
            }

            let bundle = try VMBundle.load(from: bundleURL)
            let spec = bundle.spec
            let metadata = bundle.metadata

            if let field {
                try printField(field, spec: spec, metadata: metadata)
                return
            }

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(spec)
                if let jsonString = String(data: data, encoding: .utf8) {
                    print(jsonString)
                }
                return
            }

            printStyledConfig(name: name, spec: spec, metadata: metadata, bundle: bundle)
        }

        private func printStyledConfig(
            name: String,
            spec: VMSpec,
            metadata: VMMetadata,
            bundle: VMBundle
        ) {
            let memGB = spec.memorySizeInBytes / (1024 * 1024 * 1024)
            let diskGB = spec.diskSizeInBytes / (1024 * 1024 * 1024)

            // Header
            print()
            print("  \(Style.bold(name))")
            let setupBadge = metadata.setupCompleted
                ? Style.green("● ready")
                : Style.yellow("○ setup pending")
            print("  \(setupBadge)")
            print()

            // Hardware
            Style.header("  ⬡ Hardware")
            Style.field("CPU", "\(spec.cpuCount) cores")
            Style.field("Memory", "\(memGB) GB")
            Style.field("Disk", "\(diskGB) GB" + Style.dim(" (APFS sparse)"))

            // Display
            Style.header("  ◻ Display")
            Style.field("Monitors", "\(spec.displayCount)")
            Style.field("Auto-resize", spec.autoResizeDisplay
                        ? Style.green("enabled") : Style.dim("disabled"))

            // Network
            Style.header("  ⬡ Network")
            Style.field("Mode", networkLabel(spec.networkMode))
            if let mac = spec.macAddress {
                Style.field("MAC address", Style.dim(mac))
            } else {
                Style.field("MAC address", Style.dim("auto"))
            }

            // Audio
            Style.header("  ♪ Audio")
            Style.field("Speaker", spec.audioEnabled
                        ? Style.green("enabled") : Style.dim("disabled"))
            Style.field("Microphone", spec.microphoneEnabled
                        ? Style.green("enabled") : Style.dim("disabled"))
            Style.field("Clipboard", spec.clipboardSharingEnabled
                        ? Style.green("enabled") : Style.dim("disabled"))

            // Shared Folders
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

            // Identity
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
            spec: VMSpec,
            metadata: VMMetadata
        ) throws {
            switch field {
            case "cpu": print(spec.cpuCount)
            case "memory": print(spec.memorySizeInBytes / (1024 * 1024 * 1024))
            case "disk": print(spec.diskSizeInBytes / (1024 * 1024 * 1024))
            case "displays": print(spec.displayCount)
            case "network": print(networkRaw(spec.networkMode))
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

        private func networkLabel(_ mode: NetworkMode) -> String {
            switch mode {
            case .nat: "NAT" + Style.dim(" (shared)")
            case .bridged(let iface): Style.info("bridged") + Style.dim(":\(iface)")
            case .isolated: Style.yellow("isolated")
            case .hostOnly: "host-only"
            }
        }

        private func networkRaw(_ mode: NetworkMode) -> String {
            switch mode {
            case .nat: "nat"
            case .bridged(let iface): "bridged:\(iface)"
            case .isolated: "isolated"
            case .hostOnly: "host-only"
            }
        }
    }
}

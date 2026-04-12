import ArgumentParser
import Foundation
import os
import SpooktacularKit

extension Spook {

    /// Lists all virtual machines.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all VMs.",
            discussion: """
                Shows all virtual machines with their status, hardware \
                configuration, and setup state. Use --json for \
                machine-readable output.

                EXAMPLES:
                  spook list
                  spook list --json
                """
        )

        @Flag(help: "Output as JSON.")
        var json: Bool = false

        func run() async throws {
            try Paths.ensureDirectories()

            let fm = FileManager.default
            let contents = try fm.contentsOfDirectory(
                at: Paths.vms,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "vm" }

            if contents.isEmpty {
                print(
                    Style.info("No VMs found.")
                    + Style.dim(" Run 'spook create <name>' to get started.")
                )
                return
            }

            let bundles: [(String, VMBundle)] = contents.compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let bundle = try VMBundle.load(from: url)
                    return (name, bundle)
                } catch {
                    Log.vm.error("Failed to load bundle '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.sorted { $0.0 < $1.0 }

            if json {
                printJSON(bundles)
            } else {
                printTable(bundles)
            }
        }

        private func printTable(_ bundles: [(String, VMBundle)]) {
            var rows: [[String]] = []

            for (name, bundle) in bundles {
                let memGB = bundle.spec.memorySizeInBytes / (1024 * 1024 * 1024)
                let diskGB = bundle.spec.diskSizeInBytes / (1024 * 1024 * 1024)
                let setup = bundle.metadata.setupCompleted
                    ? Style.green("✓ ready") : Style.dim("pending")
                let network = Style.networkLabel(bundle.spec.networkMode)
                let audio = bundle.spec.audioEnabled
                    ? Style.dim("♪") : ""

                rows.append([
                    Style.bold(name),
                    "\(bundle.spec.cpuCount) cores",
                    "\(memGB) GB",
                    "\(diskGB) GB",
                    network,
                    audio,
                    setup,
                ])
            }

            Style.table(
                headers: ["NAME", "CPU", "MEM", "DISK", "NET", "♪", "STATUS"],
                rows: rows
            )

            print()
            print(
                Style.dim("\(bundles.count) virtual machine\(bundles.count == 1 ? "" : "s")")
            )
        }

        private func printJSON(_ bundles: [(String, VMBundle)]) {
            var entries: [[String: Any]] = []
            for (name, bundle) in bundles {
                entries.append([
                    "name": name,
                    "cpu": bundle.spec.cpuCount,
                    "memoryGB": bundle.spec.memorySizeInBytes / (1024 * 1024 * 1024),
                    "diskGB": bundle.spec.diskSizeInBytes / (1024 * 1024 * 1024),
                    "displays": bundle.spec.displayCount,
                    "network": "\(bundle.spec.networkMode)",
                    "audio": bundle.spec.audioEnabled,
                    "setupCompleted": bundle.metadata.setupCompleted,
                    "id": bundle.metadata.id.uuidString,
                    "path": bundle.url.path,
                ])
            }

            if let data = try? JSONSerialization.data(
                withJSONObject: entries,
                options: [.prettyPrinted, .sortedKeys]
            ), let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        }

    }
}

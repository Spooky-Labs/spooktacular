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
            try SpooktacularPaths.ensureDirectories()

            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: SpooktacularPaths.vms,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "vm" }

            if contents.isEmpty {
                print(
                    Style.info("No VMs found.")
                    + Style.dim(" Run 'spook create <name>' to get started.")
                )
                return
            }

            let bundles: [(String, VirtualMachineBundle)] = contents.compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let bundle = try VirtualMachineBundle.load(from: url)
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

        private func printTable(_ bundles: [(String, VirtualMachineBundle)]) {
            var rows: [[String]] = []
            var runningCount = 0

            for (name, bundle) in bundles {
                let setup = bundle.metadata.setupCompleted
                    ? Style.green("✓ ready") : Style.dim("pending")
                let audio = bundle.spec.audioEnabled
                    ? Style.dim("♪") : ""

                let isRunning = PIDFile.isRunning(bundleURL: bundle.url)
                if isRunning { runningCount += 1 }

                rows.append([
                    Style.bold(name),
                    isRunning ? Style.green("● running") : Style.dim("○ stopped"),
                    "\(bundle.spec.cpuCount) cores",
                    "\(bundle.spec.memorySizeInGigabytes) GB",
                    "\(bundle.spec.diskSizeInGigabytes) GB",
                    Style.networkLabel(bundle.spec.networkMode),
                    audio,
                    setup,
                ])
            }

            Style.table(
                headers: ["NAME", "STATE", "CPU", "MEM", "DISK", "NET", "♪", "STATUS"],
                rows: rows
            )

            print()
            let vmLabel = bundles.count == 1 ? "virtual machine" : "virtual machines"
            print(
                Style.dim("\(bundles.count) \(vmLabel), \(runningCount) running")
            )
        }

        private func printJSON(_ bundles: [(String, VirtualMachineBundle)]) {
            var entries: [[String: Any]] = []
            for (name, bundle) in bundles {
                entries.append([
                    "name": name,
                    "running": PIDFile.isRunning(bundleURL: bundle.url),
                    "cpu": bundle.spec.cpuCount,
                    "memorySizeInGigabytes": bundle.spec.memorySizeInGigabytes,
                    "diskSizeInGigabytes": bundle.spec.diskSizeInGigabytes,
                    "displays": bundle.spec.displayCount,
                    "network": bundle.spec.networkMode.serialized,
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

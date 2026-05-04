import ArgumentParser
import Foundation
import os
import SpooktacularKit

extension Spooktacular {

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

        @Flag(name: [.short, .long], help: "Output as JSON.")
        var json: Bool = false

        @Flag(name: [.customLong("ip")], help: "Include the resolved IP address (adds a column, or a field in JSON).")
        var includeIP: Bool = false

        @Flag(name: [.customLong("running")], help: "Only list running VMs.")
        var runningOnly: Bool = false

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

            var bundles: [(String, VirtualMachineBundle)] = contents.compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let bundle = try VirtualMachineBundle.load(from: url)
                    return (name, bundle)
                } catch {
                    Log.vm.error("Failed to load bundle '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.sorted { $0.0 < $1.0 }

            if runningOnly {
                bundles = bundles.filter { PIDFile.isRunning(bundleURL: $0.1.url) }
            }

            // Resolve IPs once, up front, so the table rendering stays sync.
            var ipByName: [String: String] = [:]
            if includeIP {
                for (name, bundle) in bundles {
                    guard PIDFile.isRunning(bundleURL: bundle.url),
                          let mac = bundle.spec.macAddress,
                          let ip = try? await IPResolver.resolveIP(macAddress: mac)
                    else { continue }
                    ipByName[name] = ip
                }
            }

            if json {
                printJSON(bundles, ipByName: ipByName)
            } else {
                printTable(bundles, ipByName: ipByName)
            }
        }

        private func printTable(_ bundles: [(String, VirtualMachineBundle)], ipByName: [String: String] = [:]) {
            var rows: [[String]] = []
            var runningCount = 0

            for (name, bundle) in bundles {
                let setup = bundle.metadata.setupCompleted
                    ? Style.green("✓ ready") : Style.dim("pending")
                let audio = bundle.spec.audioEnabled
                    ? Style.dim("♪") : ""

                let isRunning = PIDFile.isRunning(bundleURL: bundle.url)
                if isRunning { runningCount += 1 }

                var row: [String] = [
                    Style.bold(name),
                    isRunning ? Style.green("● running") : Style.dim("○ stopped"),
                    "\(bundle.spec.cpuCount) cores",
                    "\(bundle.spec.memorySizeInGigabytes) GB",
                    "\(bundle.spec.diskSizeInGigabytes) GB",
                    Style.networkLabel(bundle.spec.networkMode),
                    audio,
                    setup,
                ]
                if includeIP {
                    row.append(ipByName[name] ?? Style.dim("—"))
                }
                rows.append(row)
            }

            var headers = ["NAME", "STATE", "CPU", "MEM", "DISK", "NET", "♪", "STATUS"]
            if includeIP { headers.append("IP") }
            Style.table(headers: headers, rows: rows)

            print()
            let vmLabel = bundles.count == 1 ? "virtual machine" : "virtual machines"
            print(
                Style.dim("\(bundles.count) \(vmLabel), \(runningCount) running")
            )
        }

        private func printJSON(_ bundles: [(String, VirtualMachineBundle)], ipByName: [String: String] = [:]) {
            struct VMEntry: Encodable {
                let name: String
                let running: Bool
                let cpu: Int
                let memorySizeInGigabytes: UInt64
                let diskSizeInGigabytes: UInt64
                let displays: Int
                let network: String
                let audio: Bool
                let setupCompleted: Bool
                let id: String
                let path: String
                let ip: String?
            }

            let entries = bundles.map { (name, bundle) in
                VMEntry(
                    name: name,
                    running: PIDFile.isRunning(bundleURL: bundle.url),
                    cpu: bundle.spec.cpuCount,
                    memorySizeInGigabytes: bundle.spec.memorySizeInGigabytes,
                    diskSizeInGigabytes: bundle.spec.diskSizeInGigabytes,
                    displays: bundle.spec.displayCount,
                    network: bundle.spec.networkMode.serialized,
                    audio: bundle.spec.audioEnabled,
                    setupCompleted: bundle.metadata.setupCompleted,
                    id: bundle.metadata.id.uuidString,
                    path: bundle.url.path,
                    ip: ipByName[name]
                )
            }

            if let data = try? VirtualMachineBundle.encoder.encode(entries),
               let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        }

    }
}

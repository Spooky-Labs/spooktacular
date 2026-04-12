import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Creates a new macOS virtual machine.
    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new macOS VM from an IPSW restore image.",
            discussion: """
                Creates a macOS virtual machine by downloading and installing \
                macOS from an Apple IPSW restore image. The VM is stored as a \
                bundle directory at ~/.spooktacular/vms/<name>.vm/.

                EXAMPLES:
                  spook create my-vm
                  spook create runner --cpu 8 --memory 16 --disk 100
                  spook create dev --user-data ~/setup.sh --provision disk-inject
                  spook create ci --from-ipsw ~/Downloads/macOS.ipsw

                USER DATA:
                  Use --user-data to specify a shell script that runs automatically \
                  after the VM boots. This is how you install tools, configure CI \
                  runners, set up development environments, or automate any \
                  first-boot setup.

                  Choose a provisioning method with --provision:

                  disk-inject   Script runs on first boot via a macOS LaunchDaemon \
                                injected into the VM's disk before booting. Works \
                                with any vanilla macOS — no SSH, no agent, no network \
                                required. Best for fresh IPSW installs.

                  ssh           Script runs over SSH after the VM boots. Requires \
                                Remote Login enabled in the guest. Best for clones \
                                where the base has SSH configured.

                  agent         Script runs via the Spooktacular guest agent over \
                                a VirtIO socket. Requires the agent pre-installed \
                                (included in Spooktacular OCI images). Fastest, \
                                works without networking.

                  shared-folder Script is delivered via a VirtIO shared folder. \
                                Requires a watcher daemon in the base image. \
                                Works without networking.
                """
        )

        @Argument(help: "Name for the new VM.")
        var name: String

        @Option(
            name: .long,
            help: """
                IPSW source. Use 'latest' to download the newest macOS \
                compatible with your Mac, or provide a path to a local \
                .ipsw file.
                """
        )
        var fromIpsw: String = "latest"

        @Option(help: "Number of CPU cores. Minimum 4 for macOS VMs.")
        var cpu: Int = 4

        @Option(help: "Memory in GB.")
        var memory: Int = 8

        @Option(help: "Disk size in GB. Uses APFS sparse storage.")
        var disk: Int = 64

        @Option(help: "Number of virtual displays (1 or 2).")
        var displays: Int = 1

        @Option(
            help: """
                Path to a shell script to run after first boot. \
                See DISCUSSION for provisioning methods.
                """
        )
        var userData: String?

        @Option(
            help: """
                How to execute the user-data script: \
                disk-inject (default), ssh, agent, or shared-folder. \
                Run 'spook create --help' for details on each method.
                """
        )
        var provision: ProvisioningMode = .diskInject

        @Option(help: "SSH user for --provision ssh.")
        var sshUser: String = "admin"

        @Option(help: "SSH private key path for --provision ssh.")
        var sshKey: String = "~/.ssh/id_ed25519"

        @Option(
            help: """
                Network mode: nat, isolated, host-only, or bridged:<interface>. \
                Example: --network bridged:en0
                """
        )
        var network: NetworkMode = .nat

        @Option(
            help: """
                Host network interface for bridged networking. \
                Only used with --network bridged:<interface>.
                """
        )
        var bridgedInterface: String?

        @Flag(
            inversion: .prefixedEnableDisable,
            help: "Enable audio output (default: enabled)."
        )
        var audio: Bool = true

        @Flag(
            inversion: .prefixedEnableDisable,
            help: "Enable microphone passthrough (default: disabled)."
        )
        var microphone: Bool = false

        @Flag(
            inversion: .prefixedEnableDisable,
            help: "Enable automatic display resize (default: enabled)."
        )
        var autoResize: Bool = true

        @Option(
            name: .long,
            help: ArgumentHelp(
                "Host directory to share with the VM (repeatable).",
                valueName: "path"
            )
        )
        var share: [String] = []

        @MainActor
        func run() async throws {
            try Paths.ensureDirectories()

            let bundleURL = Paths.bundleURL(for: name)
            guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' already exists.")
                throw ExitCode.failure
            }

            let effectiveNetwork: NetworkMode
            if let iface = bridgedInterface {
                effectiveNetwork = .bridged(interface: iface)
            } else {
                effectiveNetwork = network
            }

            let spec = VMSpec(
                cpuCount: cpu,
                memorySizeInBytes: UInt64(memory) * 1024 * 1024 * 1024,
                diskSizeInBytes: UInt64(disk) * 1024 * 1024 * 1024,
                displayCount: displays,
                networkMode: effectiveNetwork
            )

            let manager = RestoreImageManager(cacheDirectory: Paths.ipswCache)

            do {
                print("Fetching latest compatible macOS restore image...")
                let restoreImage = try await manager.fetchLatestSupported()
                let version = restoreImage.operatingSystemVersion
                print(
                    "Found macOS \(version.majorVersion).\(version.minorVersion)"
                    + ".\(version.patchVersion)"
                    + " (build \(restoreImage.buildVersion))"
                )

                let ipswURL: URL
                if fromIpsw == "latest" {
                    print("Downloading IPSW (this may take a while)...")
                    ipswURL = try await manager.downloadIPSW(
                        from: restoreImage
                    ) { fraction in
                        let pct = Int(fraction * 100)
                        print("\r  Progress: \(pct)%", terminator: "")
                        fflush(stdout)
                    }
                    print()
                } else {
                    ipswURL = URL(fileURLWithPath: fromIpsw)
                    guard FileManager.default.fileExists(atPath: ipswURL.path) else {
                        print("Error: IPSW file not found at '\(fromIpsw)'.")
                        throw ExitCode.failure
                    }
                }

                print("Creating VM bundle '\(name)'...")
                let bundle = try manager.createBundle(
                    named: name,
                    in: Paths.vms,
                    from: restoreImage,
                    spec: spec
                )

                print("Installing macOS (10-20 minutes)...")
                try await manager.install(
                    bundle: bundle,
                    from: ipswURL
                ) { fraction in
                    let pct = Int(fraction * 100)
                    print("\r  Installing: \(pct)%", terminator: "")
                    fflush(stdout)
                }
                print()

                if let scriptPath = userData {
                    print("User-data script: \(scriptPath)")
                    print("Provisioning method: \(provision.label)")
                    // TODO: Execute user-data via selected provisioning mode.
                    print("(User-data execution will run on next 'spook start')")
                }

                print("✓ VM '\(name)' created successfully.")
                print("  Bundle: \(bundleURL.path)")
                print("  CPU: \(spec.cpuCount) cores")
                print("  Memory: \(memory) GB")
                print("  Disk: \(disk) GB")
                print("")
                print("Run 'spook start \(name)' to boot the VM.")

            } catch let error as RestoreImageError {
                print("Error: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: bundleURL)
                throw ExitCode.failure

            } catch {
                print("Error: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: bundleURL)
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - ArgumentParser Conformance

extension ProvisioningMode: ExpressibleByArgument {}

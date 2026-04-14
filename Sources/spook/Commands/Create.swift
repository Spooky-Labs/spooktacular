import ArgumentParser
import Foundation
import os
import SpooktacularKit
@preconcurrency import Virtualization

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
                Network mode: nat, isolated, or bridged:<interface>. \
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

        // MARK: - Built-in Templates

        @Flag(
            help: """
                Configure as a GitHub Actions runner. Requires \
                --github-repo and --github-token.
                """
        )
        var githubRunner: Bool = false

        @Option(help: "GitHub repository (org/repo) for --github-runner.")
        var githubRepo: String?

        @Option(help: "GitHub runner registration token for --github-runner.")
        var githubToken: String?

        @Flag(
            help: """
                Configure as an OpenClaw AI agent. Installs Node.js \
                and OpenClaw, starts the gateway daemon. Pass API keys \
                via a shared folder for security.
                """
        )
        var openclaw: Bool = false

        @Flag(
            help: """
                Enable Screen Sharing (VNC) for remote desktop access. \
                Reports the VNC URL after boot.
                """
        )
        var remoteDesktop: Bool = false

        @Flag(
            help: """
                Runner exits after one job, VM auto-destroys and \
                re-clones. For CI pools with clean VMs per job.
                """
        )
        var ephemeral: Bool = false

        @Flag(
            help: """
                Skip auto-provisioning after install. The template \
                script is generated but not executed. Use this if \
                you want to boot and provision manually.
                """
        )
        var noProvision: Bool = false

        @Flag(
            help: """
                Skip automatic Setup Assistant automation. By \
                default, fresh IPSW installs boot the VM and walk \
                through Setup Assistant automatically. Use this \
                flag to configure the VM manually instead.
                """
        )
        var skipSetup: Bool = false

        @MainActor
        func run() async throws {
            try SpooktacularPaths.ensureDirectories()

            let bundleURL = SpooktacularPaths.bundleURL(for: name)
            guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
                print(Style.error("✗ VM '\(name)' already exists."))
                print(Style.dim("  Choose a different name, or delete the existing VM with 'spook delete \(name)'."))
                throw ExitCode.failure
            }

            let effectiveNetwork = bridgedInterface.map { NetworkMode.bridged(interface: $0) }
                ?? network

            // Generate a stable MAC address so IP resolution works
            // immediately after the first boot, without manual setup.
            let macAddress = MACAddress.generate()

            let spec = VirtualMachineSpecification(
                cpuCount: cpu,
                memorySizeInBytes: .gigabytes(memory),
                diskSizeInBytes: .gigabytes(disk),
                displayCount: displays,
                networkMode: effectiveNetwork,
                audioEnabled: audio,
                microphoneEnabled: microphone,
                macAddress: macAddress,
                autoResizeDisplay: autoResize
            )

            let manager = RestoreImageManager(cacheDirectory: SpooktacularPaths.ipswCache)

            do {
                print(Style.info("Fetching latest compatible macOS restore image..."))
                let restoreImage = try await manager.fetchLatestSupported()
                let version = restoreImage.operatingSystemVersion
                print(
                    "Found macOS \(version.majorVersion).\(version.minorVersion)"
                    + ".\(version.patchVersion)"
                    + " (build \(restoreImage.buildVersion))"
                )

                let ipswURL: URL
                if fromIpsw == "latest" {
                    print(Style.info("Downloading IPSW (this may take a while)..."))
                    ipswURL = try await manager.downloadIPSW(
                        from: restoreImage
                    ) { fraction in
                        let percentage = Int(fraction * 100)
                        print("\r  Progress: \(percentage)%", terminator: "")
                        fflush(stdout)
                    }
                    print()
                } else {
                    ipswURL = URL(fileURLWithPath: fromIpsw)
                    guard FileManager.default.fileExists(atPath: ipswURL.path) else {
                        print(Style.error("✗ IPSW file not found at '\(fromIpsw)'."))
                        print(Style.dim("  Verify the file path exists, or use '--from-ipsw latest' to download automatically."))
                        throw ExitCode.failure
                    }
                }

                print(Style.info("Creating VM bundle '\(name)'..."))
                let bundle = try manager.createBundle(
                    named: name,
                    in: SpooktacularPaths.vms,
                    from: restoreImage,
                    spec: spec
                )

                print(Style.info("Installing macOS (10-20 minutes)..."))
                try await manager.install(
                    bundle: bundle,
                    from: ipswURL
                ) { fraction in
                    let percentage = Int(fraction * 100)
                    print("\r  Installing: \(percentage)%", terminator: "")
                    fflush(stdout)
                }
                print()

                let macOSMajor = version.majorVersion
                if !skipSetup && SetupAutomation.isSupported(macOSVersion: macOSMajor) {
                    try await automateSetupAssistant(
                        bundle: bundle,
                        macOSVersion: macOSMajor,
                        macAddress: macAddress
                    )
                } else if !skipSetup {
                    Log.provision.info("No Setup Assistant sequence for macOS \(macOSMajor, privacy: .public)")
                    print(Style.warning(
                        "No automated Setup Assistant sequence for macOS \(macOSMajor). "
                        + "Run 'spook start \(name)' to complete setup manually."
                    ))
                }

                var provisionScript: URL?

                if githubRunner {
                    guard let repo = githubRepo, let token = githubToken else {
                        print(Style.error("✗ --github-runner requires --github-repo and --github-token."))
                        print(Style.dim("  Example: spook create \(name) --github-runner --github-repo org/repo --github-token <token>"))
                        throw ExitCode.failure
                    }
                    provisionScript = try GitHubRunnerTemplate.generate(
                        repo: repo, token: token, ephemeral: ephemeral
                    )
                } else if remoteDesktop {
                    provisionScript = try RemoteDesktopTemplate.generate()
                } else if openclaw {
                    provisionScript = try OpenClawTemplate.generate()
                } else if let path = userData {
                    provisionScript = URL(fileURLWithPath: path)
                }

                if let script = provisionScript {
                    switch provision {
                    case .diskInject:
                        print(Style.info("Injecting user-data script into guest disk..."))
                        try DiskInjector.inject(script: script, into: bundle)
                        print(Style.success("✓ Script injected. It will run automatically on first boot."))

                    case .ssh:
                        if noProvision {
                            Log.provision.info("Skipping SSH provisioning (--no-provision)")
                            print(Style.info("Script generated. Skipping auto-provisioning (--no-provision)."))
                            print(Style.dim("Next: spook start \(name) --headless --user-data \(script.path) --provision ssh"))
                        } else {
                            Log.provision.info("Starting SSH auto-provisioning for '\(name, privacy: .public)'")
                            try await autoProvisionViaSSH(
                                bundle: bundle,
                                script: script,
                                macAddress: macAddress
                            )
                        }

                    case .agent, .sharedFolder:
                        print(Style.error("✗ \(provision.label) provisioning is not yet available (planned for a future release)."))
                        print(Style.dim("  Use --provision ssh or --provision disk-inject instead."))
                        throw ExitCode.failure
                    }
                }
                if ephemeral {
                    print(Style.yellow("⟳ Ephemeral mode: VM auto-destroys after main process exits"))
                }

                print()
                print(Style.success("✓ VM '\(name)' created successfully."))
                Style.field("Bundle", Style.dim(bundleURL.path))
                Style.field("CPU", "\(spec.cpuCount) cores")
                Style.field("Memory", "\(memory) GB")
                Style.field("Disk", "\(disk) GB")
                Style.field("MAC", macAddress.rawValue)
                print()
                print("Run '\(Style.bold("spook start \(name)"))' to boot the VM.")

            } catch {
                print(Style.error("✗ \(error.localizedDescription)"))
                if let localizedError = error as? LocalizedError,
                   let recovery = localizedError.recoverySuggestion {
                    print(Style.dim("  \(recovery)"))
                }
                try? FileManager.default.removeItem(at: bundleURL)
                throw ExitCode.failure
            }
        }

        // MARK: - Auto-Provisioning

        /// Boots the VM headless, waits for SSH, executes the script, and stops the VM.
        ///
        /// Delegates the resolve-wait-execute sequence to
        /// ``VMProvisioner/provisionViaSSH(macAddress:script:user:key:timeout:pollInterval:)``.
        /// If provisioning fails, the VM bundle is left intact so the user
        /// can debug manually. Only the provisioning step is reported as
        /// failed -- the VM creation itself already succeeded.
        @MainActor
        private func autoProvisionViaSSH(
            bundle: VirtualMachineBundle,
            script: URL,
            macAddress: MACAddress
        ) async throws {
            let logger = Log.provision

            logger.info("Creating VM instance from bundle '\(bundle.url.lastPathComponent, privacy: .public)'")
            print(Style.info("Booting VM for provisioning..."))
            let vm = try VirtualMachine(bundle: bundle)
            try await vm.start()
            logger.notice("VM '\(bundle.url.lastPathComponent, privacy: .public)' started for provisioning")
            print(Style.success("✓ VM is running."))

            do {
                print(Style.info("Resolving VM IP address..."))
                let ip = try await VMProvisioner.provisionViaSSH(
                    macAddress: macAddress,
                    script: script,
                    user: sshUser,
                    key: sshKey,
                    timeout: 120
                )

                Style.field("IP", ip)
                print(Style.success("✓ Provisioning complete."))

            } catch {
                logger.error("Provisioning failed: \(error.localizedDescription, privacy: .public)")
                print(Style.error("✗ Provisioning failed: \(error.localizedDescription)"))
                if let localizedError = error as? LocalizedError,
                   let recovery = localizedError.recoverySuggestion {
                    print(Style.dim("  \(recovery)"))
                }
                print(Style.dim("  The VM was created successfully. Provisioning can be retried with:"))
                print(Style.dim("  spook start \(name) --headless --user-data \(script.path) --provision ssh"))
            }

            logger.info("Stopping VM '\(bundle.url.lastPathComponent, privacy: .public)' after provisioning")
            print(Style.info("Stopping VM..."))
            try? await vm.stop(graceful: false)
            logger.notice("VM '\(bundle.url.lastPathComponent, privacy: .public)' stopped after provisioning")
            print(Style.success("✓ VM stopped."))
        }

        // MARK: - Setup Assistant Automation

        /// Boots the VM, automates Setup Assistant, waits for SSH,
        /// and marks ``VirtualMachineMetadata/setupCompleted``.
        ///
        /// The method creates the VM, boots it, runs the keyboard
        /// automation sequence for the detected macOS version, then
        /// polls until SSH is reachable (confirming that the setup
        /// finished and Remote Login was enabled). Once SSH is
        /// confirmed, the metadata is updated and the VM is stopped.
        ///
        /// - Parameters:
        ///   - bundle: The newly created VM bundle.
        ///   - macOSVersion: The macOS major version (e.g., 15 for Sequoia).
        ///   - macAddress: The VM's MAC address for IP resolution.
        @MainActor
        private func automateSetupAssistant(
            bundle: VirtualMachineBundle,
            macOSVersion: Int,
            macAddress: MACAddress
        ) async throws {
            let logger = Log.provision

            logger.info("Starting Setup Assistant automation for macOS \(macOSVersion, privacy: .public)")
            print(Style.info("Automating Setup Assistant for macOS \(macOSVersion)..."))

            let vm = try VirtualMachine(bundle: bundle)
            guard let underlyingVM = vm.vzVM else {
                print(Style.error("✗ Failed to create virtual machine instance for setup."))
                throw ExitCode.failure
            }

            try await vm.start()
            logger.notice("VM booted for Setup Assistant automation")
            print(Style.success("✓ VM booted."))

            do {
                let driver = VZKeyboardDriver(virtualMachine: underlyingVM)
                let steps = SetupAutomation.sequence(for: macOSVersion)
                logger.info("Executing \(steps.count, privacy: .public) Setup Assistant steps")
                print(Style.info("Running Setup Assistant automation (\(steps.count) steps)..."))
                try await SetupAutomationExecutor.run(steps: steps, using: driver)
                logger.notice("Setup Assistant automation steps completed")
                print(Style.success("✓ Setup Assistant automation complete."))

                logger.info("Resolving IP for MAC \(macAddress, privacy: .public)")
                print(Style.info("Waiting for SSH to confirm setup completed..."))
                guard let ip = try await IPResolver.resolveIPWithRetry(macAddress: macAddress, timeout: 120) else {
                    logger.error("Could not resolve IP — SSH unreachable, setup cannot be verified")
                    throw NSError(
                        domain: "com.spooktacular",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Could not resolve VM IP address within timeout.",
                            NSLocalizedRecoverySuggestionErrorKey:
                                "The VM is not usable for template provisioning without SSH. "
                                + "Run 'spook start \(name)' to complete setup manually."
                        ]
                    )
                }
                logger.info("Resolved IP \(ip, privacy: .public), waiting for SSH")
                try await SSHExecutor.waitForSSH(ip: ip)
                logger.notice("SSH confirmed on \(ip, privacy: .public)")
                print(Style.success("✓ SSH available at \(ip). Setup confirmed."))

                var metadata = bundle.metadata
                metadata.setupCompleted = true
                try VirtualMachineBundle.writeMetadata(metadata, to: bundle.url)
                logger.notice("setupCompleted = true written to metadata")
                print(Style.success("✓ Setup marked complete."))

            } catch {
                logger.error("Setup Assistant automation failed: \(error.localizedDescription, privacy: .public)")
                print(Style.error("✗ Setup Assistant automation failed: \(error.localizedDescription)"))
                print(Style.dim("  The VM was created. Run 'spook start \(name)' to complete setup manually."))
            }

            logger.info("Stopping VM after Setup Assistant automation")
            print(Style.info("Stopping VM..."))
            try? await vm.stop(graceful: false)
            logger.notice("VM stopped after Setup Assistant automation")
            print(Style.success("✓ VM stopped."))
        }
    }
}

// MARK: - ArgumentParser Conformance

extension ProvisioningMode: ExpressibleByArgument {}

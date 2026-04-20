import ArgumentParser
import Foundation
import os
import SpooktacularKit
@preconcurrency import Virtualization

extension Spooktacular {

    /// Creates a new macOS virtual machine.
    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new macOS VM from an IPSW restore image.",
            discussion: """
                Creates a macOS virtual machine by downloading and installing \
                macOS from an Apple IPSW restore image. The VM is stored as a \
                bundle directory at ~/.spooktacular/vms/<name>.vm/.

                EXIT CODES:
                  0   VM created successfully
                  1   Network failure, IPSW unreachable, or VM already exists
                  2   Insufficient disk space on the host volume
                  3   Invalid input (bad name, unsupported host, ipsw not found)

                EXAMPLES:
                  spook create my-vm
                  spook create runner --cpu 8 --memory 16 --disk 100
                  spook create dev --user-data ~/setup.sh --provision disk-inject
                  spook create ci --from-ipsw ~/Downloads/macOS.ipsw
                  spook create my-vm --json   # machine-parsable success payload

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
                --github-repo and --github-token-keychain.
                """
        )
        var githubRunner: Bool = false

        @Option(help: "GitHub repository (org/repo) for --github-runner.")
        var githubRepo: String?

        @Option(
            name: .customLong("github-token-keychain"),
            help: """
                Keychain account name under service \
                `com.spooktacular.github`. The only accepted way \
                to supply the runner registration token — env-var, \
                CLI-flag, and file-path paths were removed to keep \
                the PAT out of `ps`, `launchctl print`, and \
                plaintext-on-disk exposures. \
                Store with: `security add-generic-password -s \
                com.spooktacular.github -a <account> -w <token> -U`.
                """
        )
        var githubTokenKeychain: String?

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

        @Flag(
            help: "Print a machine-readable JSON result to stdout on success."
        )
        var json: Bool = false

        // MARK: - Guest OS selection (Track H)

        @Option(
            name: .long,
            help: """
                Guest operating system. `macos` (default) downloads \
                an IPSW restore image and runs Apple's installer \
                pipeline. `linux` takes an installer ISO (see \
                --installer-iso) and boots it via EFI firmware. \
                The bundle layer provisions different on-disk \
                artifacts per OS — see Sources/SpooktacularCore/GuestOS.swift.
                """
        )
        var os: String = "macos"

        @Option(
            name: .customLong("installer-iso"),
            help: """
                Path to a Linux installer ISO (required when \
                --os linux). The file is copied into the bundle \
                as `installer.iso` and attached as a read-only \
                USB mass-storage device so the EFI firmware \
                boots it ahead of the main disk.
                """
        )
        var installerISO: String?

        @Flag(
            name: .customLong("rosetta"),
            help: """
                Expose Rosetta 2 to the Linux guest through a \
                virtio-fs share tagged `rosetta`.  After boot, \
                mount it in the guest and register the runtime \
                with binfmt to run x86_64 ELF binaries natively. \
                Ignored for macOS guests. Requires Rosetta to \
                be available on the host (`softwareupdate \
                --install-rosetta`).
                """
        )
        var rosetta: Bool = false

        @MainActor
        func run() async throws {
            try SpooktacularPaths.ensureDirectories()

            let startedAt = Date()

            let bundleURL = try SpooktacularPaths.bundleURL(for: name)
            guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
                if json {
                    printJSONError(
                        code: "bundle-exists",
                        message: "VM '\(name)' already exists.",
                        hint: "Choose a different name, or delete the existing VM with 'spook delete \(name)'."
                    )
                } else {
                    print(Style.error("✗ VM '\(name)' already exists."))
                    print(Style.dim("  Choose a different name, or delete the existing VM with 'spook delete \(name)'."))
                }
                throw ExitCode(CLIExit.generalFailure)
            }

            let effectiveNetwork = bridgedInterface.map { NetworkMode.bridged(interface: $0) }
                ?? network

            // Generate a stable MAC address so IP resolution works
            // immediately after the first boot, without manual setup.
            let macAddress = MACAddress.generate()

            // ────── Guest-OS branch (Track H) ──────
            //
            // Linux uses a radically different install flow:
            // no Apple IPSW, no macOS Setup Assistant, no
            // VZMacOSInstaller — just EFI firmware booting
            // from an installer ISO we attach as read-only
            // USB mass storage. Branch early and exit so the
            // rest of this method stays the macOS-specific
            // restore-image pipeline it has always been.
            if os == "linux" {
                try await runLinuxCreate(
                    bundleURL: bundleURL,
                    macAddress: macAddress,
                    network: effectiveNetwork
                )
                return
            }
            if os != "macos" {
                if json {
                    printJSONError(
                        code: "invalid-os",
                        message: "--os must be 'macos' or 'linux' (got '\(os)').",
                        hint: "Run 'spook create --help' for supported guest operating systems."
                    )
                } else {
                    print(Style.error("✗ --os must be 'macos' or 'linux' (got '\(os)')."))
                    print(Style.dim("  Run 'spook create --help' for supported guest operating systems."))
                }
                throw ExitCode(CLIExit.validation)
            }

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
                    if !json { print(Style.info("Downloading IPSW (this may take a while)...")) }
                    ipswURL = try await manager.downloadIPSW(
                        from: restoreImage
                    ) { snapshot in
                        // Only render terminal progress when stdout
                        // is a TTY and we're not in JSON mode —
                        // keeps pipelines clean.
                        guard !json else { return }
                        let percentage = Int(snapshot.fraction * 100)
                        let label = snapshot.resumed ? "Resuming" : "Progress"
                        print("\r  \(label): \(percentage)%", terminator: "")
                        fflush(stdout)
                    }
                    if !json { print() }
                } else {
                    ipswURL = URL(filePath: fromIpsw)
                    guard FileManager.default.fileExists(atPath: ipswURL.path) else {
                        if json {
                            printJSONError(
                                code: "ipsw-not-found",
                                message: "IPSW file not found at '\(fromIpsw)'.",
                                hint: "Verify the file path exists, or use '--from-ipsw latest' to download automatically."
                            )
                        } else {
                            print(Style.error("✗ IPSW file not found at '\(fromIpsw)'."))
                            print(Style.dim("  Verify the file path exists, or use '--from-ipsw latest' to download automatically."))
                        }
                        throw ExitCode(CLIExit.validation)
                    }
                }

                if !json { print(Style.info("Creating VM bundle '\(name)'...")) }
                let bundle = try await manager.createBundle(
                    named: name,
                    in: SpooktacularPaths.vms,
                    from: restoreImage,
                    spec: spec
                )

                if !json { print(Style.info("Installing macOS (10-20 minutes)...")) }
                try await manager.install(
                    bundle: bundle,
                    from: ipswURL
                ) { fraction in
                    guard !json else { return }
                    let percentage = Int(fraction * 100)
                    print("\r  Installing: \(percentage)%", terminator: "")
                    fflush(stdout)
                }
                if !json { print() }

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
                // Track whether we OWN the script (template-generated,
                // lives in ~/Library/Caches/com.spooktacular/provisioning/)
                // or whether it's operator-supplied via `--user-data
                // <path>`. We only clean up the ones we own; deleting
                // an operator's file would be surprising.
                var ownsScript = false

                if githubRunner {
                    guard let repo = githubRepo else {
                        print(Style.error("✗ --github-runner requires --github-repo."))
                        print(Style.dim("  Example: spook create \(name) --github-runner --github-repo org/repo --github-token-keychain org-acme"))
                        throw ExitCode.failure
                    }
                    guard let account = githubTokenKeychain else {
                        print(Style.error("✗ --github-runner requires --github-token-keychain <account>."))
                        print(Style.dim("  Store the token first: security add-generic-password -s com.spooktacular.github -a <account> -w <token> -U"))
                        throw ExitCode.failure
                    }
                    let token: String
                    do {
                        token = try GitHubTokenResolver.resolve(
                            keychainAccount: account
                        )
                    } catch {
                        print(Style.error("✗ \(error.localizedDescription)"))
                        if let suggestion = (error as? LocalizedError)?.recoverySuggestion {
                            print(Style.dim("  \(suggestion)"))
                        }
                        throw ExitCode.failure
                    }
                    provisionScript = try GitHubRunnerTemplate.generate(
                        repo: repo, token: token, ephemeral: ephemeral
                    )
                    ownsScript = true
                } else if remoteDesktop {
                    provisionScript = try RemoteDesktopTemplate.generate()
                    ownsScript = true
                } else if openclaw {
                    provisionScript = try OpenClawTemplate.generate()
                    ownsScript = true
                } else if let path = userData {
                    provisionScript = URL(filePath: path)
                }

                if let script = provisionScript {
                    // Cleanup policy: only delete the host-side script
                    // AFTER the VM has actually consumed it (disk
                    // injection copied it, SSH executed it). The
                    // `--no-provision` path leaves the script on disk
                    // intentionally — the operator will hand it to a
                    // later `spook start --user-data <path>`. In all
                    // consuming cases, shrink the on-disk window from
                    // "host lifetime" to "this command's duration."
                    // GitHub registration tokens are 1-hour single-use,
                    // so once the VM's `./config.sh --token` runs, the
                    // secret is burned regardless. See
                    // docs/DATA_AT_REST.md § "Known limits."
                    var consumedScript = false
                    defer {
                        if ownsScript && consumedScript {
                            // Best-effort in a defer: surface the
                            // failure through the CLI logger but
                            // don't propagate (defer has no throw
                            // channel). The script's 0o700 perms
                            // already gate read access.
                            do {
                                try ScriptFile.cleanup(scriptURL: script)
                            } catch {
                                Log.provision.error("Script cleanup failed: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                    }

                    switch provision {
                    case .diskInject:
                        print(Style.info("Injecting user-data script into guest disk..."))
                        try DiskInjector.inject(script: script, into: bundle)
                        print(Style.success("✓ Script injected. It will run automatically on first boot."))
                        consumedScript = true

                    case .ssh:
                        if noProvision {
                            Log.provision.info("Skipping SSH provisioning (--no-provision)")
                            print(Style.info("Script generated. Skipping auto-provisioning (--no-provision)."))
                            print(Style.dim("Next: spook start \(name) --headless --user-data \(script.path) --provision ssh"))
                            // Do NOT mark consumed — the operator needs
                            // the path later.
                        } else {
                            Log.provision.info("Starting SSH auto-provisioning for '\(name, privacy: .public)'")
                            try await autoProvisionViaSSH(
                                bundle: bundle,
                                script: script,
                                macAddress: macAddress
                            )
                            consumedScript = true
                        }

                    case .agent, .sharedFolder:
                        print(Style.error("✗ \(provision.label) provisioning is not yet available (planned for a future release)."))
                        print(Style.dim("  Use --provision ssh or --provision disk-inject instead."))
                        throw ExitCode(CLIExit.validation)
                    }
                }
                if ephemeral {
                    print(Style.yellow("⟳ Ephemeral mode: VM auto-destroys after main process exits"))
                }

                let elapsed = Date().timeIntervalSince(startedAt)

                if json {
                    struct CreateResult: Encodable {
                        let name: String
                        let path: String
                        let id: String
                        let metadata: Metadata
                        let elapsedSeconds: Double

                        struct Metadata: Encodable {
                            let cpuCount: Int
                            let memorySizeInGigabytes: UInt64
                            let diskSizeInGigabytes: UInt64
                            let displayCount: Int
                            let networkMode: String
                            let macAddress: String?
                        }
                    }
                    let payload = CreateResult(
                        name: name,
                        path: bundleURL.path,
                        id: bundle.metadata.id.uuidString,
                        metadata: .init(
                            cpuCount: spec.cpuCount,
                            memorySizeInGigabytes: spec.memorySizeInGigabytes,
                            diskSizeInGigabytes: spec.diskSizeInGigabytes,
                            displayCount: spec.displayCount,
                            networkMode: spec.networkMode.serialized,
                            macAddress: macAddress.rawValue
                        ),
                        elapsedSeconds: elapsed
                    )
                    printJSON(payload)
                } else {
                    print()
                    print(Style.success("✓ VM '\(name)' created successfully."))
                    Style.field("Bundle", Style.dim(bundleURL.path))
                    Style.field("CPU", "\(spec.cpuCount) cores")
                    Style.field("Memory", "\(memory) GB")
                    Style.field("Disk", "\(disk) GB")
                    Style.field("MAC", macAddress.rawValue)
                    Style.field("Elapsed", formatElapsed(elapsed))
                    print()
                    print("Run '\(Style.bold("spook start \(name)"))' to boot the VM.")
                }

            } catch {
                if json {
                    printJSONError(
                        code: classifyErrorCode(error),
                        message: error.localizedDescription,
                        hint: (error as? LocalizedError)?.recoverySuggestion
                    )
                } else {
                    print(Style.error("✗ \(error.localizedDescription)"))
                    if let localizedError = error as? LocalizedError,
                       let recovery = localizedError.recoverySuggestion {
                        print(Style.dim("  \(recovery)"))
                    }
                }
                try? FileManager.default.removeItem(at: bundleURL)
                throw ExitCode(classifyExitCode(error))
            }
        }

        // MARK: - Linux create flow (Track H.3)

        /// Creates a Linux VM bundle pointed at an installer
        /// ISO. No IPSW, no Setup Assistant, no macOS
        /// installer — just the minimal artifacts EFI firmware
        /// needs to boot the ISO on first start.
        ///
        /// Flow:
        /// 1. Validate `--installer-iso` (required, must exist).
        /// 2. Build a `VirtualMachineSpecification(guestOS: .linux)`.
        ///    `VirtualMachineBundle.create` notices the Linux
        ///    guest and provisions `efi-nvram.bin` automatically
        ///    per Track H.2.
        /// 3. Allocate a sparse RAW disk image via `ftruncate`.
        ///    The image is zero bytes on disk initially —
        ///    APFS sparse semantics — but presents as the
        ///    configured GiB size to the firmware / installer.
        /// 4. Copy the ISO into the bundle as `installer.iso`.
        ///    `FileManager.copyItem` falls through to APFS
        ///    `clonefile(2)` when source and destination live
        ///    on the same volume, so copying a 3 GiB Fedora
        ///    ISO from `~/Downloads` to `~/.spooktacular/vms`
        ///    is near-instant on modern Macs.
        /// 5. Print bundle info + next-step hint.
        @MainActor
        private func runLinuxCreate(
            bundleURL: URL,
            macAddress: MACAddress,
            network: NetworkMode
        ) async throws {
            guard let isoPath = installerISO else {
                if json {
                    printJSONError(
                        code: "missing-installer-iso",
                        message: "--os linux requires --installer-iso <path>.",
                        hint: "Example: spooktacular create my-fedora --os linux --installer-iso ~/Downloads/Fedora-Workstation-Live-43-1.6.aarch64.iso"
                    )
                } else {
                    print(Style.error("✗ --os linux requires --installer-iso <path>."))
                    print(Style.dim("  Example: spooktacular create my-fedora --os linux --installer-iso ~/Downloads/Fedora-Workstation-Live-43-1.6.aarch64.iso"))
                }
                throw ExitCode(CLIExit.validation)
            }

            let isoURL = URL(filePath: (isoPath as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: isoURL.path) else {
                if json {
                    printJSONError(
                        code: "installer-iso-not-found",
                        message: "Installer ISO not found at '\(isoURL.path)'.",
                        hint: "Verify the path exists; tilde expansion and relative paths are supported."
                    )
                } else {
                    print(Style.error("✗ Installer ISO not found at '\(isoURL.path)'."))
                    print(Style.dim("  Verify the path exists; tilde expansion and relative paths are supported."))
                }
                throw ExitCode(CLIExit.validation)
            }

            let spec = VirtualMachineSpecification(
                cpuCount: cpu,
                memorySizeInBytes: .gigabytes(memory),
                diskSizeInBytes: .gigabytes(disk),
                displayCount: displays,
                networkMode: network,
                audioEnabled: audio,
                microphoneEnabled: microphone,
                macAddress: macAddress,
                autoResizeDisplay: autoResize,
                guestOS: .linux,
                rosettaEnabled: rosetta
            )

            if !json {
                print(Style.info("Creating Linux VM bundle '\(name)'..."))
            }

            // Bundle creation: writes config.json, metadata.json,
            // and (because spec.guestOS == .linux) provisions
            // the empty EFI NVRAM file.
            let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)

            // Allocate the primary disk image through the
            // shared `DiskImageAllocator`, which prefers
            // ASIF (Apple Sparse Image Format) for
            // portability and falls back to RAW on older
            // hosts.  ASIF keeps the file actually-small
            // across non-APFS transfers (Track B's
            // portable-bundle story); RAW is sparse only on
            // APFS and materializes zeros when copied
            // elsewhere.  See `DiskImageAllocator` docs for
            // the format tradeoff.
            let diskURL = bundleURL.appendingPathComponent(VirtualMachineBundle.diskImageFileName)
            let diskFormat: DiskImageAllocator.Format
            do {
                diskFormat = try await DiskImageAllocator.create(
                    at: diskURL,
                    sizeInBytes: spec.diskSizeInBytes
                )
            } catch {
                try? FileManager.default.removeItem(at: bundleURL)
                if json {
                    printJSONError(
                        code: "disk-image-create-failed",
                        message: error.localizedDescription,
                        hint: (error as? LocalizedError)?.recoverySuggestion
                    )
                } else {
                    print(Style.error("✗ \(error.localizedDescription)"))
                    if let hint = (error as? LocalizedError)?.recoverySuggestion {
                        print(Style.dim("  \(hint)"))
                    }
                }
                throw ExitCode.failure
            }
            if !json {
                print(Style.dim("  Disk format: \(diskFormat.rawValue.uppercased())"))
            }

            // Copy the ISO into the bundle. APFS clonefile
            // semantics (via FileManager.copyItem on same
            // volume) make this effectively free.
            if !json {
                print(Style.info("Copying installer ISO into bundle..."))
            }
            try FileManager.default.copyItem(at: isoURL, to: bundle.installerISOURL)

            // Propagate the bundle's data-at-rest protection
            // class to the newly-written disk + ISO. Matches
            // what writeSpec / writeMetadata do after atomic
            // renames land — see docs/DATA_AT_REST.md.
            try? BundleProtection.propagate(to: bundleURL)

            if json {
                print(#"{"status":"created","name":"\#(name)","path":"\#(bundleURL.path)","guest_os":"linux"}"#)
            } else {
                print(Style.success("✓ Linux VM '\(name)' created."))
                print(Style.dim("  Bundle: \(bundleURL.path)"))
                print(Style.dim("  Next:   spooktacular start \(name)"))
                print(Style.dim("          (boots into the installer — follow the Fedora prompts)"))
            }
        }

        // MARK: - Error Classification

        /// Maps known error types to stable `--json` error codes.
        private func classifyErrorCode(_ error: Error) -> String {
            if error is CancellationError { return "cancelled" }
            if let restore = error as? RestoreImageError {
                switch restore {
                case .unsupportedHost:          return "unsupported-host"
                case .unsupportedHardwareModel: return "unsupported-hardware"
                case .incompatibleHost:         return "incompatible-host"
                case .downloadFailed:           return "download-failed"
                }
            }
            return "create-failed"
        }

        /// Maps known error types to the documented exit code table
        /// so shell scripts can branch on failure mode.
        private func classifyExitCode(_ error: Error) -> Int32 {
            if let restore = error as? RestoreImageError {
                switch restore {
                case .unsupportedHost, .unsupportedHardwareModel, .incompatibleHost:
                    return CLIExit.validation
                case .downloadFailed:
                    return CLIExit.generalFailure
                }
            }
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
                return CLIExit.diskSpace
            }
            return CLIExit.generalFailure
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
                let screenReader = VZScreenReader(vmView: driver.vmView)
                let steps = try SetupAutomation.sequence(for: macOSVersion)
                logger.info("Executing \(steps.count, privacy: .public) Setup Assistant steps")
                print(Style.info("Running Setup Assistant automation (\(steps.count) steps)..."))
                try await SetupAutomationExecutor.run(
                    steps: steps,
                    using: driver,
                    screenReader: screenReader
                )
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

        // MARK: - GitHub token resolution

    }
}

// MARK: - ArgumentParser Conformance

extension ProvisioningMode: ExpressibleByArgument {}

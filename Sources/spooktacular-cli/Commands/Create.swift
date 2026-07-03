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
                                with any vanilla macOS — no SSH, no network \
                                required. Best for fresh IPSW installs.

                  ssh           Script runs over SSH after the VM boots. Requires \
                                Remote Login enabled in the guest. Best for clones \
                                where the base has SSH configured.

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
                disk-inject (default), ssh, or shared-folder. \
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
            help: """
                How to install Spooktacular Guest Tools inside \
                the macOS VM: disabled (no Guest Tools app — \
                ideal for CI runners that don't need the SPICE \
                clipboard bridge or menu-bar UI) or installed \
                (default — app lands in /Applications/; user \
                flips the menu-bar Launch-at-Login toggle after \
                first login). This only controls the Guest Tools \
                app; it's independent of first-boot script \
                provisioning (--user-data, --github-runner, \
                etc.), which always runs through the separate \
                Spooktacular Provisioner LaunchDaemon installed \
                during Setup Assistant automation. Ignored for \
                Linux guests.
                """
        )
        var guestTools: GuestToolsInstallMode = .installed

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
                `com.spooktacular.github`. The item must hold a \
                long-lived GitHub personal access token (PAT) with \
                repo admin scope (fine-grained "Administration" \
                read/write, or classic `repo`) — NOT a runner \
                registration token. Registration tokens expire in \
                one hour, so `spook create` uses the PAT to mint a \
                fresh one automatically, seconds before the VM \
                boots. The Keychain is the only accepted way to \
                supply the PAT — env-var, CLI-flag, and file-path \
                paths were removed to keep it out of `ps`, \
                `launchctl print`, and plaintext-on-disk exposures. \
                Store with: `security add-generic-password -s \
                com.spooktacular.github -a <account> -w <PAT> -U`.
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
            help: """
                Skip auto-starting the VM after provisioning. \
                Currently only affects --github-runner (every \
                other template already leaves the VM stopped for \
                a later 'spook start'). Combine with --skip-setup \
                as an advanced escape hatch: the runner script is \
                still generated and injected, but nothing boots or \
                polls it automatically — you start the VM and \
                register the runner by hand.
                """
        )
        var noStart: Bool = false

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

            // Under the UUID primary-key scheme, the bundle
            // directory is `<fresh-uuid>.vm` — two VMs with
            // the same display name never collide on disk, so
            // the old "bundle-exists" guard no longer fires.
            // Display-name uniqueness is a UX preference, not
            // a filesystem constraint; if users want to keep
            // names unique they can inspect `spook list`.
            try SpooktacularPaths.validateDisplayName(name)
            let bundleID = UUID()
            let bundleURL = SpooktacularPaths.bundleURL(for: bundleID)

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

            // Validate everything statically knowable about the
            // --github-runner invocation BEFORE spending 10-20
            // minutes on an IPSW download and macOS install: flag
            // presence, scope shape, template exclusivity, provision
            // mode, and the --skip-setup/--no-start interaction.
            // Only the Keychain PAT resolution and token mint stay
            // late (the token's one-hour TTL must cover the guest's
            // first boot). See ``RunnerCreateFlowPlan`` for the pure
            // decision logic.
            var runnerAutoStart = false
            var runnerRepo = ""
            var runnerKeychainAccount = ""
            if githubRunner {
                guard let repo = githubRepo else {
                    if json {
                        printJSONError(
                            code: "runner-validation",
                            message: "--github-runner requires --github-repo.",
                            hint: "Example: spook create \(name) --github-runner --github-repo org/repo --github-token-keychain org-acme"
                        )
                    } else {
                        print(Style.error("✗ --github-runner requires --github-repo."))
                        print(Style.dim("  Example: spook create \(name) --github-runner --github-repo org/repo --github-token-keychain org-acme"))
                    }
                    throw ExitCode(CLIExit.validation)
                }
                guard let account = githubTokenKeychain else {
                    if json {
                        printJSONError(
                            code: "runner-validation",
                            message: "--github-runner requires --github-token-keychain <account>.",
                            hint: "Store the PAT first: security add-generic-password -s com.spooktacular.github -a <account> -w <PAT with repo admin scope> -U"
                        )
                    } else {
                        print(Style.error("✗ --github-runner requires --github-token-keychain <account>."))
                        print(Style.dim("  Store the PAT first: security add-generic-password -s com.spooktacular.github -a <account> -w <PAT with repo admin scope> -U"))
                    }
                    throw ExitCode(CLIExit.validation)
                }
                do {
                    // Rejects malformed --github-repo values (missing
                    // slash, extra path segments) now instead of after
                    // the install.
                    _ = try GitHubRunnerScope("repos/\(repo)")
                    try RunnerCreateFlowPlan.validateTemplateExclusivity(
                        remoteDesktop: remoteDesktop,
                        openclaw: openclaw,
                        hasUserData: userData != nil
                    )
                    try RunnerCreateFlowPlan.validateProvisionMode(
                        isDiskInject: provision == .diskInject
                    )
                    runnerAutoStart = try RunnerCreateFlowPlan.autoStartDecision(
                        skipSetup: skipSetup,
                        noStart: noStart
                    )
                } catch {
                    if json {
                        printJSONError(
                            code: "runner-validation",
                            message: error.localizedDescription,
                            hint: (error as? LocalizedError)?.recoverySuggestion
                        )
                    } else {
                        print(Style.error("✗ \(error.localizedDescription)"))
                        if let recovery = (error as? LocalizedError)?.recoverySuggestion {
                            print(Style.dim("  \(recovery)"))
                        }
                    }
                    throw ExitCode(CLIExit.validation)
                }
                runnerRepo = repo
                runnerKeychainAccount = account
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
                autoResizeDisplay: autoResize,
                guestToolsInstall: guestTools
            )

            let manager = RestoreImageManager(cacheDirectory: SpooktacularPaths.ipswCache)

            // Set at the end of the do-block below, once the VM is
            // fully created and announced. Read by the runner
            // provisioning phase, which intentionally runs OUTSIDE
            // that do/catch — see the comment at its call site.
            var createdBundle: VirtualMachineBundle?

            do {
                // Restore-image resolution is source-dependent.
                //
                //   - local path — load the on-disk IPSW via
                //     `VZMacOSRestoreImage.image(from:)`. No network
                //     I/O; `fetchLatestSupported()`'s call to Apple's
                //     catalog is not required here.
                //   - `latest`   — fetch from Apple's catalog to
                //     learn the current IPSW URL, then resume-download.
                //
                // Previously this path unconditionally called
                // `fetchLatestSupported()` before branching, which
                // made every create (including local-IPSW creates)
                // depend on Apple's catalog reachability AND on the
                // catalog's newest version being installable on this
                // host — a cached IPSW older than the network
                // "latest" was rejected even though it's perfectly
                // installable. Mirrors the fix already shipped in
                // `AppState.runMacOSCreate` for the GUI's local-IPSW
                // path.
                let restoreImage: VZMacOSRestoreImage
                let ipswURL: URL
                if fromIpsw == "latest" {
                    if !json { print(Style.info("Fetching latest compatible macOS restore image...")) }
                    restoreImage = try await manager.fetchLatestSupported()
                    let version = restoreImage.operatingSystemVersion
                    if !json {
                        print(
                            "Found macOS \(version.majorVersion).\(version.minorVersion)"
                            + ".\(version.patchVersion)"
                            + " (build \(restoreImage.buildVersion))"
                        )
                    }
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
                    if !json { print(Style.info("Loading local IPSW '\(ipswURL.lastPathComponent)'...")) }
                    restoreImage = try await VZMacOSRestoreImage.image(from: ipswURL)
                    let version = restoreImage.operatingSystemVersion
                    if !json {
                        print(
                            "Found macOS \(version.majorVersion).\(version.minorVersion)"
                            + ".\(version.patchVersion)"
                            + " (build \(restoreImage.buildVersion))"
                        )
                    }
                }

                // Fail fast, BEFORE the 10-20 minute macOS install
                // begins: --github-runner depends entirely on
                // ``SetupAutomation`` to install the Spooktacular
                // Provisioner LaunchDaemon (see
                // ``RunnerCreateFlowPlan/validateMacOSVersionSupport(githubRunner:macOSMajorVersion:)``'s
                // doc comment). Checking here — right after the
                // restore image's version is known, rather than
                // after `manager.install()` — means an operator who
                // passes `--from-ipsw` pointing at an unsupported
                // macOS major gets an immediate, actionable error
                // instead of a guaranteed ~10-minute online-poll
                // timeout after losing the install time too.
                do {
                    try RunnerCreateFlowPlan.validateMacOSVersionSupport(
                        githubRunner: githubRunner,
                        macOSMajorVersion: restoreImage.operatingSystemVersion.majorVersion
                    )
                } catch {
                    if json {
                        printJSONError(
                            code: "unsupported-macos-runner",
                            message: error.localizedDescription,
                            hint: (error as? LocalizedError)?.recoverySuggestion
                        )
                    } else {
                        print(Style.error("✗ \(error.localizedDescription)"))
                        if let recovery = (error as? LocalizedError)?.recoverySuggestion {
                            print(Style.dim("  \(recovery)"))
                        }
                    }
                    throw ExitCode(CLIExit.validation)
                }

                if !json { print(Style.info("Creating VM bundle '\(name)' (id=\(bundleID.uuidString))...")) }
                let bundle = try await manager.createBundle(
                    id: bundleID,
                    displayName: name,
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

                let macOSMajor = restoreImage.operatingSystemVersion.majorVersion
                if !skipSetup && SetupAutomation.isSupported(macOSVersion: macOSMajor) {
                    // Zero-touch provisioner install: stage
                    // `Spooktacular Provisioner.pkg` into the
                    // bundle's provisioning share BEFORE Setup
                    // Assistant automation starts, so it's already
                    // sitting on the share (mounted by every macOS
                    // guest's `applyProvisioning` virtio-fs device)
                    // when the automation's typed `installer`
                    // command runs inside the guest.
                    //
                    // Only worth doing when something will actually
                    // consume the provisioner daemon afterward: a
                    // first-boot script about to be disk-injected
                    // (only `--provision disk-inject` writes
                    // `first-boot.sh` to the share — `--provision
                    // ssh` never touches it) or Guest Tools being
                    // installed. `githubRunner` / `remoteDesktop` /
                    // `openclaw` / `userData` are the only sources
                    // of a provisioning script later in this method
                    // (see the `provisionScript` assignment below),
                    // and all four are already-parsed flags at this
                    // point, so the check doesn't need to wait for
                    // that assignment to run.
                    let willInjectFirstBootScript = provision == .diskInject
                        && (githubRunner || remoteDesktop || openclaw || userData != nil)
                    var installProvisioner = willInjectFirstBootScript || guestTools.installsAppBundle

                    if installProvisioner {
                        if let pkgURL = AppBundleBootstrapTemplate.locateProvisionerPkg() {
                            try FileManager.default.createDirectory(
                                at: bundle.provisionDirectoryURL,
                                withIntermediateDirectories: true
                            )
                            let destination = bundle.provisionDirectoryURL
                                .appendingPathComponent(pkgURL.lastPathComponent)
                            try? FileManager.default.removeItem(at: destination)
                            try FileManager.default.copyItem(at: pkgURL, to: destination)
                            if !json { print(Style.info("Staged provisioner pkg for zero-touch install.")) }
                        } else {
                            // Soft warn, mirroring the Guest Tools
                            // bundle-not-found path below — dev
                            // builds that never ran build-app.sh
                            // don't have a pkg to stage. Skipping
                            // `installProvisioner` here (rather than
                            // leaving it true) keeps the typed
                            // `installer` command from running
                            // against a file that was never copied.
                            if !json { print(Style.dim("  Provisioner pkg not found — run build-app.sh to produce Spooktacular.app/Contents/Applications/Spooktacular Guest Tools.app/Contents/Resources/Spooktacular Provisioner.pkg. Continuing without zero-touch provisioning.")) }
                            installProvisioner = false
                        }
                    }

                    try await automateSetupAssistant(
                        bundle: bundle,
                        macOSVersion: macOSMajor,
                        macAddress: macAddress,
                        installProvisioner: installProvisioner
                    )
                } else if !skipSetup {
                    Log.provision.info("No Setup Assistant sequence for macOS \(macOSMajor, privacy: .public)")
                    if !json {
                        print(Style.warning(
                            "No automated Setup Assistant sequence for macOS \(macOSMajor). "
                            + "Run 'spook start \(name)' to complete setup manually."
                        ))
                    }
                }

                var provisionScript: URL?
                // Track whether we OWN the script (template-generated,
                // lives in ~/Library/Caches/com.spooktacular/provisioning/)
                // or whether it's operator-supplied via `--user-data
                // <path>`. We only clean up the ones we own; deleting
                // an operator's file would be surprising.
                var ownsScript = false

                // --github-runner is handled entirely separately,
                // after this create flow's usual success summary —
                // see the ``provisionGitHubRunner(bundle:bundleURL:autoStart:)``
                // call near the end of this method. It mints its
                // registration token late (seconds before boot) and
                // always disk-injects, so it never sets
                // `provisionScript` here.
                if remoteDesktop {
                    provisionScript = try RemoteDesktopTemplate.generate()
                    ownsScript = true
                } else if openclaw {
                    provisionScript = try OpenClawTemplate.generate()
                    ownsScript = true
                } else if let path = userData {
                    provisionScript = URL(filePath: path)
                }

                // Install Spooktacular Guest Tools via the
                // Apple-native direct-copy path (`ditto` onto
                // the mounted guest data volume). Two-way
                // toggle via ``--guest-tools`` honours user
                // intent:
                //
                //   .disabled   → skip, guest stays pristine
                //   .installed  → app lands in /Applications
                //
                // Launch-at-login is owned by the guest app's
                // own menu-bar `SMAppService.mainApp` toggle,
                // so this step is fully unprivileged — no
                // `/Library/LaunchAgents/` plist, no
                // `osascript` admin prompt.
                //
                // Locator returns `nil` during dev iteration
                // before `build-app.sh` has produced the
                // nested `.app` wrapper; that's a soft warn,
                // not a create-blocking error.
                if guestTools.installsAppBundle {
                    if let appBundle = AppBundleBootstrapTemplate.locateGuestToolsBundle() {
                        if !json { print(Style.info("Installing Spooktacular Guest Tools into guest...")) }
                        // If Setup Assistant automation just ran (the
                        // `automateSetupAssistant` call above),
                        // `vm.stop(graceful: false)` returned only
                        // moments ago and Apple's VZ XPC service can
                        // still hold this bundle's `disk.img` open for
                        // a few seconds — the same lock
                        // `RestoreImageManager.install` already waits
                        // out for its own callers (see that method's
                        // doc comment for the `lsof`-confirmed root
                        // cause). `DiskInjector.installGuestTools`
                        // shells straight to `diskutil image attach`
                        // with no pre-flight of its own, so wait here
                        // before attaching — closes the exact race a
                        // live E2E run hit.
                        await RestoreImageManager.waitForArtifactsReleased(bundle: bundle)
                        do {
                            try DiskInjector.installGuestTools(
                                appBundle: appBundle,
                                into: bundle
                            )
                            if !json { print(Style.success("✓ Guest Tools installed (\(guestTools.displayName)).")) }
                        } catch {
                            // Deliberately swallowed, not rethrown:
                            // the macOS install (10-20 minutes) and
                            // any Setup Assistant automation already
                            // succeeded, and the VM is fully usable
                            // without Guest Tools. Letting this
                            // propagate to the generic `catch` below
                            // would delete `bundleURL` over what,
                            // post-wait, is most likely a residual
                            // transient lock — destroying a long
                            // install for a retryable, non-fatal step.
                            Log.provision.error("Guest Tools install failed: \(error.localizedDescription, privacy: .public)")
                            emitWarning([
                                "✗ Guest Tools install failed: \(error.localizedDescription)",
                                "  The VM was created successfully without Guest Tools. Recreate with --guest-tools installed once the issue clears, or install it later from the Spooktacular app.",
                            ])
                        }
                    } else {
                        if !json { print(Style.dim("  Guest Tools bundle not found — run build-app.sh to produce Spooktacular.app/Contents/Applications/Spooktacular Guest Tools.app. Continuing without install.")) }
                    }
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
                        if !json { print(Style.info("Injecting user-data script into guest disk...")) }
                        try DiskInjector.inject(script: script, into: bundle)
                        if !json { print(Style.success("✓ Script injected. It will run automatically on first boot.")) }
                        consumedScript = true

                    case .ssh:
                        if noProvision {
                            Log.provision.info("Skipping SSH provisioning (--no-provision)")
                            if !json {
                                print(Style.info("Script generated. Skipping auto-provisioning (--no-provision)."))
                                print(Style.dim("Next: spook start \(name) --headless --user-data \(script.path) --provision ssh"))
                            }
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

                    case .sharedFolder:
                        if json {
                            printJSONError(
                                code: "unsupported-provision-mode",
                                message: "\(provision.label) provisioning is not yet available (planned for a future release).",
                                hint: "Use --provision ssh or --provision disk-inject instead."
                            )
                        } else {
                            print(Style.error("✗ \(provision.label) provisioning is not yet available (planned for a future release)."))
                            print(Style.dim("  Use --provision ssh or --provision disk-inject instead."))
                        }
                        throw ExitCode(CLIExit.validation)
                    }
                }
                if ephemeral && !json {
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
                    if githubRunner && runnerAutoStart {
                        print(Style.info("Provisioning GitHub Actions runner '\(name)'..."))
                    } else {
                        print("Run '\(Style.bold("spook start \(name)"))' to boot the VM.")
                    }
                }

                createdBundle = bundle

            } catch let failure as RunnerSetupAutomationFailure {
                // --github-runner + failed Setup Assistant automation:
                // fail fast WITHOUT deleting the bundle — the macOS
                // install itself succeeded and the VM is fully usable
                // once setup is finished by hand — and WITHOUT falling
                // through to the runner-provisioning phase below,
                // which would mint a registration token, inject the
                // runner script, and boot into a guaranteed online-
                // poll timeout (the Spooktacular Provisioner that
                // would execute the script never installed). See
                // ``RunnerSetupAutomationFailure``.
                reportSetupAutomationFailureForRunner(failure.underlying)
                throw ExitCode(classifyExitCode(failure.underlying))
            } catch let exit as ExitCode {
                // A validation guard inside this do-block (IPSW not
                // found, or --github-runner with a macOS version
                // that has no Setup Assistant automation sequence)
                // already printed its own single, clean error
                // message and picked its own documented exit code
                // before throwing. Passing it straight through
                // avoids double-reporting a second, uninformative
                // "ArgumentParser.ExitCode error N" line AND avoids
                // `classifyExitCode` silently downgrading the
                // documented code (e.g. validation's 3 falling back
                // to generalFailure's 1, since `ExitCode` itself
                // isn't one of the cases `classifyExitCode` knows
                // how to read).
                throw exit
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

            // --github-runner: mint the registration token late
            // (seconds before boot), inject the runner script, then
            // — unless --no-start opted out — boot the VM headless
            // and poll GitHub until the runner reports online. The
            // VM is left running; see
            // ``provisionGitHubRunner(bundle:bundleURL:autoStart:)``.
            //
            // This deliberately runs OUTSIDE the do/catch above: by
            // this point VM creation succeeded and its success
            // summary (including the --json payload) has already
            // been printed, so a late runner-phase failure — a
            // GitHub rate limit, the concurrent-VM capacity cap, a
            // boot error — must NOT fall into a catch that deletes
            // the bundle and re-announces failure. That would
            // discard a 10-20 minute install over a retryable error
            // and emit a second, contradictory --json document. The
            // bundle is kept; the error is reported; the exit code
            // is non-zero.
            if githubRunner, let createdBundle {
                do {
                    try await provisionGitHubRunner(
                        bundle: createdBundle,
                        bundleURL: bundleURL,
                        repo: runnerRepo,
                        keychainAccount: runnerKeychainAccount,
                        autoStart: runnerAutoStart
                    )
                } catch let exit as ExitCode {
                    // Only the degraded-poll path throws ExitCode
                    // (runner never confirmed online after the VM
                    // stopped) — its warning was already printed at
                    // poll time, so rethrow without a second report.
                    throw exit
                } catch {
                    reportRunnerProvisioningFailure(error)
                    throw ExitCode.failure
                }
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
                // Guest Tools is a macOS-only `.app`; Linux
                // guests use `spice-vdagent` + native tooling
                // for the same functions. Force `.disabled`
                // so the spec JSON reflects reality even if
                // the user passed `--guest-tools auto-launch`
                // on the command line (ignored for Linux, but
                // an unsuppressed default would silently
                // mislead a later inspector).
                rosettaEnabled: rosetta,
                guestToolsInstall: .disabled
            )

            if !json {
                print(Style.info("Creating Linux VM bundle '\(name)'..."))
            }

            // Bundle creation: writes config.json, metadata.json,
            // and (because spec.guestOS == .linux) provisions
            // the empty EFI NVRAM file. The bundle URL's
            // basename is a UUID so `create` mints metadata
            // with the matching id.
            let bundle = try VirtualMachineBundle.create(
                at: bundleURL,
                spec: spec,
                displayName: name
            )

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
            if !json { print(Style.info("Booting VM for provisioning...")) }
            // Post-release construction: this runs either right
            // after `RestoreImageManager.install()` (when Setup
            // Assistant automation was skipped or unsupported) or
            // right after `automateSetupAssistant` stopped its VM —
            // in both cases a prior VZVirtualMachine on this same
            // bundle was just released and its XPC service may still
            // hold the file lock. See `VirtualMachine.makeAfterInstall`.
            let vm = try await VirtualMachine.makeAfterInstall(bundle: bundle) { [json] attempt, maxAttempts in
                if !json { print(Style.dim("  Retrying VM construction (attempt \(attempt)/\(maxAttempts))...")) }
            }
            try await vm.start()
            logger.notice("VM '\(bundle.url.lastPathComponent, privacy: .public)' started for provisioning")
            if !json { print(Style.success("✓ VM is running.")) }

            do {
                if !json { print(Style.info("Resolving VM IP address...")) }
                let ip = try await VMProvisioner.provisionViaSSH(
                    macAddress: macAddress,
                    script: script,
                    user: sshUser,
                    key: sshKey,
                    timeout: 120
                )

                if !json {
                    Style.field("IP", ip)
                    print(Style.success("✓ Provisioning complete."))
                }

            } catch {
                logger.error("Provisioning failed: \(error.localizedDescription, privacy: .public)")
                if !json {
                    print(Style.error("✗ Provisioning failed: \(error.localizedDescription)"))
                    if let localizedError = error as? LocalizedError,
                       let recovery = localizedError.recoverySuggestion {
                        print(Style.dim("  \(recovery)"))
                    }
                    print(Style.dim("  The VM was created successfully. Provisioning can be retried with:"))
                    print(Style.dim("  spook start \(name) --headless --user-data \(script.path) --provision ssh"))
                }
            }

            logger.info("Stopping VM '\(bundle.url.lastPathComponent, privacy: .public)' after provisioning")
            if !json { print(Style.info("Stopping VM...")) }
            try? await vm.stop(graceful: false)
            logger.notice("VM '\(bundle.url.lastPathComponent, privacy: .public)' stopped after provisioning")
            if !json { print(Style.success("✓ VM stopped.")) }
        }

        // MARK: - Setup Assistant Automation

        /// Thrown by ``automateSetupAssistant(bundle:macOSVersion:macAddress:installProvisioner:)``
        /// when Setup Assistant automation fails under
        /// `--github-runner`, per
        /// ``RunnerCreateFlowPlan/setupAutomationFailureIsFatal(githubRunner:)``.
        ///
        /// `run()`'s outer catch matches this type specifically —
        /// see the comment at that catch site — so it can report the
        /// failure and exit non-zero WITHOUT deleting the VM bundle
        /// (the macOS install itself succeeded) and WITHOUT falling
        /// through to mint a registration token, inject the runner
        /// script, or boot again.
        private struct RunnerSetupAutomationFailure: Error {
            /// The underlying error `SetupAutomationExecutor.run` (or
            /// the SSH-confirmation step) threw.
            let underlying: Error
        }

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
        ///   - installProvisioner: Forwarded to
        ///     ``SetupAutomation/sequence(for:username:password:installProvisioner:)``.
        ///     Pass `true` only once `Spooktacular Provisioner.pkg`
        ///     has actually been copied into `bundle`'s
        ///     provisioning share — see the call site in `run()`.
        ///
        /// - Throws: ``RunnerSetupAutomationFailure`` if automation
        ///   fails and ``RunnerCreateFlowPlan/setupAutomationFailureIsFatal(githubRunner:)``
        ///   says the failure is fatal for this create (always true
        ///   when `--github-runner` is active) — the VM is still
        ///   stopped first, exactly as in the swallowed case, so the
        ///   caller never has to. For a plain desktop create the
        ///   failure is logged and swallowed, matching prior
        ///   behavior.
        @MainActor
        private func automateSetupAssistant(
            bundle: VirtualMachineBundle,
            macOSVersion: Int,
            macAddress: MACAddress,
            installProvisioner: Bool = false
        ) async throws {
            let logger = Log.provision

            logger.info("Starting Setup Assistant automation for macOS \(macOSVersion, privacy: .public)")
            if !json { print(Style.info("Automating Setup Assistant for macOS \(macOSVersion)...")) }

            // Captured on failure so the fail-fast decision below can
            // run AFTER the VM is stopped (same shutdown as the
            // swallowed case) rather than duplicating the stop
            // sequence in a second catch. `vm` is optional because
            // construction/boot themselves can fail — in that case
            // there is nothing to stop, but the failure must still
            // flow through this same capture-and-report path rather
            // than escaping uncaught, which would skip straight to
            // `run()`'s generic catch and delete the freshly-installed
            // bundle (see the doc comment on
            // ``RunnerSetupAutomationFailure``: any failure at this
            // stage must preserve the bundle, since macOS install
            // itself already succeeded).
            var automationFailure: Error?
            var vm: VirtualMachine?

            do {
                // `RestoreImageManager.install()` already waits for
                // the just-finished installer's XPC-backed file lock
                // on `auxiliary.bin` / `disk.img` to clear before
                // returning — see that method's doc comment for why
                // the lock is held by a separate
                // `com.apple.Virtualization.VirtualMachine.xpc`
                // process (confirmed via `ps` / `lsof`), not by
                // anything in our own object graph, and so can't be
                // released any faster by dropping a Swift reference
                // sooner on our end. `makeAfterInstall` below only
                // covers the small residual TOCTOU gap between that
                // wait and this construction call.
                let constructedVM = try await VirtualMachine.makeAfterInstall(bundle: bundle) { [json] attempt, maxAttempts in
                    if !json { print(Style.dim("  Retrying VM construction (attempt \(attempt)/\(maxAttempts))...")) }
                }
                vm = constructedVM
                guard let underlyingVM = constructedVM.vzVM else {
                    throw NSError(
                        domain: "com.spooktacular",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Failed to create virtual machine instance for setup."
                        ]
                    )
                }

                try await constructedVM.start()
                logger.notice("VM booted for Setup Assistant automation")
                if !json { print(Style.success("✓ VM booted.")) }

                let driver = VZKeyboardDriver(virtualMachine: underlyingVM)
                let screenReader = VZScreenReader(vmView: driver.vmView)
                let steps = try SetupAutomation.sequence(
                    for: macOSVersion,
                    installProvisioner: installProvisioner
                )
                logger.info("Executing \(steps.count, privacy: .public) Setup Assistant steps")
                if !json { print(Style.info("Running Setup Assistant automation (\(steps.count) steps)...")) }
                // Diagnostics land in the same `provision/` directory
                // first-boot provisioning evidence already uses, so a
                // failed run and a failed gate show up side by side.
                try await SetupAutomationExecutor.run(
                    steps: steps,
                    using: driver,
                    screenReader: screenReader,
                    diagnosticsDirectory: bundle.provisionDirectoryURL
                )
                // NOT "automation complete" / "succeeded": every
                // keystroke sent and every screen gate along the way
                // was satisfied, but that only means the sequence
                // ran — it doesn't confirm Setup Assistant actually
                // finished on the guest. The SSH confirmation below
                // is the real success gate; this line just reports
                // that the keystroke phase is over.
                logger.notice("Setup Assistant keystroke sequence completed (guest state unverified until SSH confirm)")
                if !json { print(Style.info("Keystroke sequence completed — verifying guest state via SSH...")) }

                logger.info("Resolving IP for MAC \(macAddress, privacy: .public)")
                if !json { print(Style.info("Waiting for SSH to confirm setup completed...")) }
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
                if !json { print(Style.success("✓ SSH available at \(ip). Setup confirmed.")) }

                var metadata = bundle.metadata
                metadata.setupCompleted = true
                try VirtualMachineBundle.writeMetadata(metadata, to: bundle.url)
                logger.notice("setupCompleted = true written to metadata")
                if !json { print(Style.success("✓ Setup marked complete.")) }

            } catch {
                logger.error("Setup Assistant automation failed: \(error.localizedDescription, privacy: .public)")
                // Not printed in --json mode: the message is
                // reported once, cleanly, via `printJSONError` in
                // `reportSetupAutomationFailureForRunner` (fatal
                // case) or would otherwise corrupt stdout with a
                // second, free-text line (swallowed case — see the
                // `else` branch below, also gated).
                if !json { print(Style.error("✗ Setup Assistant automation failed: \(error.localizedDescription)")) }
                if RunnerCreateFlowPlan.setupAutomationFailureIsFatal(githubRunner: githubRunner) {
                    automationFailure = error
                } else if !json {
                    print(Style.dim("  The VM was created. Run 'spook start \(name)' to complete setup manually."))
                }
            }

            if let vm {
                logger.info("Stopping VM after Setup Assistant automation")
                if !json { print(Style.info("Stopping VM...")) }
                try? await vm.stop(graceful: false)
                logger.notice("VM stopped after Setup Assistant automation")
                if !json { print(Style.success("✓ VM stopped.")) }
            }

            // Fail fast under --github-runner: the Spooktacular
            // Provisioner never installed, so minting a registration
            // token, injecting the runner script, and booting again
            // below would be a guaranteed ~10-minute online-poll
            // timeout with nothing useful to diagnose. Thrown AFTER
            // the VM is stopped above so the caller doesn't have to
            // stop it again; caught by `run()`'s outer catch, which
            // reports it without deleting the (fully macOS-installed)
            // bundle — see ``RunnerSetupAutomationFailure``.
            if let automationFailure {
                throw RunnerSetupAutomationFailure(underlying: automationFailure)
            }
        }

        // MARK: - GitHub Actions Runner Provisioning

        /// Reports a runner-provisioning failure without touching
        /// the (already successfully created) VM bundle.
        ///
        /// In `--json` mode the success payload has already been
        /// written to stdout, so the failure text goes to stderr —
        /// appending a second JSON document (or free text) to
        /// stdout would corrupt single-document consumers. In
        /// normal mode it prints styled lines like every other
        /// error path in this command.
        private func reportRunnerProvisioningFailure(_ error: Error) {
            let message = "✗ Runner provisioning failed: \(error.localizedDescription)"
            let recovery = (error as? LocalizedError)?.recoverySuggestion
            let keepNote = "The VM '\(name)' was created successfully and has been kept. "
                + "Fix the issue above, then boot it with 'spook start \(name)' — or "
                + "delete it with 'spook delete \(name)'."
            if json {
                var text = message + "\n"
                if let recovery { text += "  " + recovery + "\n" }
                text += "  " + keepNote + "\n"
                FileHandle.standardError.write(Data(text.utf8))
            } else {
                print(Style.error(message))
                if let recovery {
                    print(Style.dim("  \(recovery)"))
                }
                print(Style.dim("  \(keepNote)"))
            }
        }

        /// Reports a fatal Setup Assistant automation failure that
        /// aborted a `--github-runner` create before minting a
        /// registration token, injecting the runner script, or
        /// booting again.
        ///
        /// Distinct from ``reportRunnerProvisioningFailure(_:)``:
        /// that one reports failures AFTER the runner phase already
        /// started (mint/inject/start), whose `--json` success
        /// payload has already been written to stdout, so it writes
        /// failure text to stderr only. This one fires before any of
        /// that — the create flow's own success summary was never
        /// printed either — so in `--json` mode it still owes callers
        /// a single machine-parsable error document on stdout via
        /// `printJSONError`, same as every other pre-success failure
        /// in this command. `automateSetupAssistant`'s own catch
        /// suppresses its "what failed" line in `--json` mode (like
        /// every other progress line in that function), so the
        /// message is reported exactly once, here, via
        /// `printJSONError` — this method then adds the "kept + how
        /// to recover" guidance on stderr.
        private func reportSetupAutomationFailureForRunner(_ error: Error) {
            let keepNote = "The VM '\(name)' was created and macOS installed successfully — it has been kept."
            let nextSteps = "Run 'spook start \(name)' to boot it and complete Setup Assistant by hand. "
                + "Once setup is done, either register a self-hosted GitHub Actions runner manually "
                + "inside the guest, or delete this VM ('spook delete \(name)') and re-run "
                + "'spook create --github-runner ...' once the automation failure above is fixed."
            if json {
                printJSONError(
                    code: classifyErrorCode(error),
                    message: "Setup Assistant automation failed: \(error.localizedDescription)",
                    hint: (error as? LocalizedError)?.recoverySuggestion
                )
                let text = "  " + keepNote + "\n  " + nextSteps + "\n"
                FileHandle.standardError.write(Data(text.utf8))
            } else {
                print(Style.dim("  \(keepNote)"))
                print(Style.dim("  \(nextSteps)"))
            }
        }

        /// Mints a fresh registration token, injects the runner
        /// setup script, and — unless the operator opted out via
        /// `--no-start` — boots the VM headless and polls GitHub
        /// until the runner reports online.
        ///
        /// Called AFTER Setup Assistant automation (which installs
        /// the Spooktacular Provisioner LaunchDaemon that will
        /// actually execute the injected script) and after the
        /// create flow's usual success summary has already printed.
        ///
        /// The registration token is minted here — seconds before
        /// boot — rather than earlier, because GitHub's registration
        /// tokens expire after one hour: minting it before the
        /// 10-20 minute macOS install + Setup Assistant automation
        /// would routinely hand the guest an already-expired token.
        ///
        /// - Parameters:
        ///   - bundle: The newly created VM bundle.
        ///   - bundleURL: The bundle's location on disk (for the
        ///     PID file when `autoStart` is `true`).
        ///   - repo: The `--github-repo` value, already validated
        ///     present and shape-checked (via `GitHubRunnerScope`)
        ///     by the fail-fast block at the top of `run()`.
        ///   - keychainAccount: The `--github-token-keychain` value,
        ///     already validated present. Its Keychain item is only
        ///     read here — after the install — per this method's
        ///     late-mint design.
        ///   - autoStart: Whether to boot the VM and poll for the
        ///     runner coming online. `false` when `--no-start` was
        ///     passed — the script is still generated and injected,
        ///     but nothing boots or executes it automatically.
        @MainActor
        private func provisionGitHubRunner(
            bundle: VirtualMachineBundle,
            bundleURL: URL,
            repo: String,
            keychainAccount: String,
            autoStart: Bool
        ) async throws {
            // Failures here (Keychain miss, GitHub API errors)
            // propagate to the runner-phase catch in `run()`, whose
            // json-aware reporter prints the message, recovery hint,
            // and the VM-was-kept note.
            let pat = try GitHubTokenResolver.resolve(keychainAccount: keychainAccount)

            let scope = try GitHubRunnerScope("repos/\(repo)")
            let service = GitHubRunnerService(
                auth: GitHubPATAuth(token: pat),
                http: URLSessionHTTPClient()
            )

            if !json { print(Style.info("Minting GitHub Actions runner registration token...")) }
            let issued = try await service.issueRegistrationToken(scope: scope)
            if !json { print(Style.success("✓ Registration token minted.")) }

            // GitHubRunnerTemplate always writes to the host-side
            // cache — we always own this script, unlike the shared
            // provisionScript/ownsScript dance above which also
            // handles operator-supplied --user-data paths.
            let scriptURL = try GitHubRunnerTemplate.generate(
                repo: repo,
                token: issued.token,
                ephemeral: ephemeral,
                runnerName: name
            )

            // The rendered script embeds the live registration
            // token, so the host-side copy is deleted the moment
            // injection has copied the bytes into the bundle share
            // — and on injection failure too. Deliberately NOT a
            // `defer`: the headless-hosting phase below ends through
            // signal handlers that call `Foundation.exit`, which
            // terminates the process without unwinding this frame,
            // so a deferred cleanup would never run on the mainline
            // Ctrl-C path. Nothing past this block may depend on
            // the host-side script file existing.
            if !json { print(Style.info("Injecting runner setup script into guest disk...")) }
            do {
                try DiskInjector.inject(script: scriptURL, into: bundle)
            } catch {
                try? ScriptFile.cleanup(scriptURL: scriptURL)
                throw error
            }
            do {
                try ScriptFile.cleanup(scriptURL: scriptURL)
            } catch {
                Log.provision.error("Runner script cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
            if !json { print(Style.success("✓ Script injected. The provisioner runs it automatically on first boot.")) }

            guard autoStart else {
                if !json { print(Style.dim("  --no-start: VM not started. Boot manually with 'spook start \(name)' when ready.")) }
                return
            }

            try await bootRunnerAndAwaitOnline(
                bundle: bundle,
                bundleURL: bundleURL,
                service: service,
                scope: scope,
                issuedHandle: issued.handle
            )
        }

        /// Boots the VM headless (mirroring `Start.swift`'s headless
        /// path: PID file, SIGTERM/SIGINT handling, state-stream
        /// loop), polls GitHub every 10 s for up to 10 minutes for
        /// the runner named ``name`` to report `online`, prints the
        /// result, then blocks until the VM stops — the VM is left
        /// running for as long as this process keeps running,
        /// exactly like `spook start --headless`.
        ///
        /// The process exit code reflects the poll outcome: if the
        /// runner was never confirmed online, both exit paths — the
        /// signal handlers (`Foundation.exit`) and the normal
        /// state-stream unwind (thrown `ExitCode.failure`) — report
        /// non-zero, even though the VM is (correctly) left running
        /// in the meantime because the runner may still come online.
        ///
        /// `SIGUSR1` (the `spook suspend` signal) is deliberately
        /// left at its default-ignored disposition rather than
        /// wired to `VirtualMachine.suspend()`: suspend-to-disk for
        /// a runner-created VM isn't implemented yet, and ignoring
        /// the signal makes `spook suspend` fail loudly (it times
        /// out waiting for the PID to exit) instead of silently
        /// hard-killing the guest via SIGUSR1's default disposition.
        @MainActor
        private func bootRunnerAndAwaitOnline(
            bundle: VirtualMachineBundle,
            bundleURL: URL,
            service: GitHubRunnerService,
            scope: GitHubRunnerScope,
            issuedHandle: UUID
        ) async throws {
            var bundle = bundle
            if ephemeral && !bundle.metadata.isEphemeral {
                var metadata = bundle.metadata
                metadata.isEphemeral = true
                try VirtualMachineBundle.writeMetadata(metadata, to: bundleURL)
                bundle = try VirtualMachineBundle.load(from: bundleURL)
            }

            if !json { print(Style.info("Starting VM '\(name)' headless for runner registration...")) }
            // Post-release construction: `automateSetupAssistant`
            // stopped its VM on this same bundle just before this
            // runs (token mint + script injection in between are
            // fast), so the stopped VM's XPC service may still hold
            // the file lock. See `VirtualMachine.makeAfterInstall`.
            let vm = try await VirtualMachine.makeAfterInstall(bundle: bundle) { attempt, maxAttempts in
                if !json { print(Style.dim("  Retrying VM construction (attempt \(attempt)/\(maxAttempts))...")) }
            }
            guard vm.vzVM != nil else {
                throw NSError(
                    domain: "com.spooktacular",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Failed to create a virtual machine instance for the runner boot.",
                    ]
                )
            }

            // CapacityError (too many running VMs) propagates to the
            // runner-phase catch in `run()` — the script is already
            // injected at this point, so its json-aware reporter's
            // "boot it with 'spook start'" guidance is exactly right.
            try PIDFile.writeAndEnsureCapacity(
                bundleURL: bundleURL,
                vmDirectory: SpooktacularPaths.vms
            )

            let outcome = RunnerOnlineOutcome()
            let nameCapture = name
            let isEphemeralCapture = ephemeral
            let jsonCapture = json
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    let sigName = sig == SIGTERM ? "SIGTERM" : "SIGINT"
                    if !jsonCapture {
                        print("\nReceived \(sigName) — stopping VM '\(nameCapture)'...")
                    }
                    Task { @MainActor in
                        try? await vm.stop(graceful: false)
                        cleanupRunnerVMAfterStop(
                            bundleURL: bundleURL,
                            name: nameCapture,
                            ephemeral: isEphemeralCapture,
                            json: jsonCapture
                        )
                        // Exit status must reflect whether the
                        // runner was ever confirmed online —
                        // Foundation.exit bypasses the thrown-
                        // ExitCode path below.
                        Foundation.exit(outcome.confirmed ? 0 : 1)
                    }
                }
                source.resume()
            }
            // See the DocC caveat above: `spook suspend` isn't
            // supported for runner-created VMs yet, so SIGUSR1 stays
            // at SIG_IGN rather than getting a handler wired to
            // `VirtualMachine.suspend()`.
            signal(SIGUSR1, SIG_IGN)

            try await vm.startOrResume()
            if !json { print(Style.success("✓ VM '\(name)' is running.")) }

            if !json { print(Style.info("Waiting for runner '\(name)' to come online (up to 10 minutes)...")) }
            do {
                let runner = try await service.waitForOnline(
                    named: name,
                    scope: scope,
                    deadline: Date().addingTimeInterval(600),
                    pollInterval: 10
                )
                outcome.confirmed = true
                if !json { print(Style.success("✓ Runner '\(name)' is online (GitHub runner id \(runner.id)).")) }
            } catch {
                var lines = ["⚠ Runner '\(name)' was NOT confirmed online: \(error.localizedDescription)"]
                if let recovery = (error as? LocalizedError)?.recoverySuggestion {
                    lines.append("  \(recovery)")
                }
                lines.append("  The VM is left running — the runner may still come online. Investigate with 'spook ssh \(name)' or stop with 'spook stop \(name)'.")
                lines.append("  This command will exit non-zero because the runner was not confirmed.")
                emitWarning(lines)
            }
            // The token has either already been consumed by the
            // guest's `config.sh --token` (online) or is no longer
            // something this process needs to track (timeout) — see
            // ``IssuedTokenLedger`` for why dropping it promptly is
            // good hygiene rather than a correctness requirement.
            await service.revokeRegistrationToken(handle: issuedHandle)

            if !json { print(Style.dim("Running headless. Press Ctrl+C to stop.")) }
            for await state in vm.stateStream {
                if state == .stopped || state == .error {
                    break
                }
            }
            cleanupRunnerVMAfterStop(bundleURL: bundleURL, name: name, ephemeral: ephemeral, json: json)
            if !outcome.confirmed {
                // The poll never confirmed the runner online — the
                // warning above already explained why. This is the
                // normal-unwind twin of the signal handlers' exit(1):
                // the runner-phase catch in `run()` rethrows
                // ExitCode as-is, so the process exits non-zero
                // without printing a second, redundant message.
                throw ExitCode.failure
            }
        }

        /// Prints non-fatal warning lines — styled to stdout normally;
        /// plain text to stderr in `--json` mode so stdout stays a
        /// single JSON document. Used by the runner online-poll
        /// path and by any other create-flow step (e.g. a Guest
        /// Tools install failure) that must surface a problem
        /// without corrupting `--json`'s machine-parsable payload.
        private func emitWarning(_ lines: [String]) {
            if json {
                let text = lines.joined(separator: "\n") + "\n"
                FileHandle.standardError.write(Data(text.utf8))
            } else {
                for (index, line) in lines.enumerated() {
                    print(index == 0 ? Style.warning(line) : Style.dim(line))
                }
            }
        }
    }
}

/// Whether the poll phase confirmed the runner online.
///
/// Shared between `bootRunnerAndAwaitOnline`'s mainline and its
/// SIGTERM/SIGINT handlers so BOTH exit paths report a non-zero
/// status when the runner was never verified: the signal path exits
/// via `Foundation.exit`, which cannot observe an `ExitCode` thrown
/// on the normal unwind.
@MainActor
private final class RunnerOnlineOutcome {
    var confirmed = false
}

// MARK: - Runner VM Cleanup

/// Removes the PID file and, for ephemeral VMs, deletes the bundle.
///
/// Mirrors `Start.swift`'s private `cleanupAfterStop(bundleURL:name:ephemeral:)`
/// — duplicated rather than shared because that function is
/// file-scoped to `Start.swift` and this task's brief scopes edits
/// to `Create.swift` only. Called from both the state-stream
/// observer and the signal handler in
/// ``Spooktacular/Create/bootRunnerAndAwaitOnline(bundle:bundleURL:service:scope:)``
/// to avoid duplicating cleanup logic within this file.
@MainActor
private func cleanupRunnerVMAfterStop(bundleURL: URL, name: String, ephemeral: Bool, json: Bool) {
    PIDFile.remove(from: bundleURL)
    if ephemeral {
        try? FileManager.default.removeItem(at: bundleURL)
        // Not printed in --json mode: this can land AFTER the
        // create flow's single JSON payload on the mainline stop
        // path (the VM ran headless, was Ctrl-C'd or hit its
        // ephemeral exit condition, and THEN got cleaned up here),
        // which would otherwise append a second, non-JSON line to
        // stdout.
        if !json {
            print("Ephemeral VM '\(name)' destroyed.")
        }
    }
}

// MARK: - ArgumentParser Conformance

extension ProvisioningMode: ExpressibleByArgument {}

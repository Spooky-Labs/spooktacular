import AppKit
import ArgumentParser
import Foundation
import SpooktacularKit
@preconcurrency import Virtualization

extension Spooktacular {

    /// Starts a virtual machine.
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a VM.",
            discussion: """
                Boots a stopped virtual machine. By default, a display \
                window opens showing the VM's screen. Use --headless to \
                run without a window (useful for CI runners and servers).

                Use --recovery to boot into macOS Recovery mode, which \
                allows disk repair, password resets, and reinstallation.

                You can also pass --user-data to run a provisioning \
                script on this boot, using the same mechanism as \
                'spook create'.

                EXAMPLES:
                  spook start my-vm
                  spook start my-vm --headless
                  spook start my-vm --recovery
                  spook start my-vm --user-data ~/setup.sh --provision ssh
                """
        )

        @Argument(help: "Name of the VM to start.")
        var name: String

        @Flag(help: "Run without a display window.")
        var headless: Bool = false

        @Flag(help: "Boot into macOS Recovery mode.")
        var recovery: Bool = false

        @Option(
            help: """
                Path to a shell script to run after boot. \
                See 'spook create --help' for provisioning details.
                """
        )
        var userData: String?

        @Option(
            help: """
                How to execute the user-data script: \
                disk-inject, ssh, or shared-folder.
                """
        )
        var provision: ProvisioningMode = .ssh

        @Option(help: "SSH user for --provision ssh.")
        var sshUser: String = "admin"

        @Option(help: "SSH private key path for --provision ssh.")
        var sshKey: String = "~/.ssh/id_ed25519"

        @Flag(
            help: """
                Destroy the VM after it stops. Used for CI pools \
                where each job gets a clean clone that is discarded \
                after use.
                """
        )
        var ephemeral: Bool = false

        @MainActor
        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            try SpooktacularPaths.ensureDirectories()

            if PIDFile.isRunning(bundleURL: bundleURL) {
                print(Style.error("✗ VM '\(name)' is already running."))
                throw ExitCode.failure
            }

            // Clean up stale ephemeral bundles from crashed processes.
            let fm = FileManager.default
            if let allBundles = try? fm.contentsOfDirectory(
                at: SpooktacularPaths.vms,
                includingPropertiesForKeys: nil
            ).filter({ $0.pathExtension == "vm" }) {
                for otherBundle in allBundles {
                    guard otherBundle != bundleURL else { continue }
                    if let loaded = try? VirtualMachineBundle.load(from: otherBundle),
                       loaded.metadata.isEphemeral,
                       let pid = PIDFile.read(from: otherBundle),
                       !PIDFile.isProcessAlive(pid) {
                        try? fm.removeItem(at: otherBundle)
                        print(Style.dim("Cleaned up stale ephemeral VM '\(otherBundle.deletingPathExtension().lastPathComponent)'."))
                    }
                }
            }

            var bundle = try VirtualMachineBundle.load(from: bundleURL)

            if ephemeral && !bundle.metadata.isEphemeral {
                var metadata = bundle.metadata
                metadata.isEphemeral = true
                try VirtualMachineBundle.writeMetadata(metadata, to: bundleURL)
                bundle = try VirtualMachineBundle.load(from: bundleURL)
            }

            if let scriptPath = userData {
                let scriptURL = URL(filePath: scriptPath.expandingTilde)

                switch provision {
                case .diskInject:
                    try requireScript(at: scriptURL, path: scriptPath)
                    print(Style.info("Injecting user-data script into guest disk..."))
                    try injectOrFail(label: "Disk injection") {
                        try DiskInjector.inject(script: scriptURL, into: bundle)
                    }
                    print(Style.success("✓ Script injected. It will run automatically on boot."))

                case .sharedFolder:
                    try requireScript(at: scriptURL, path: scriptPath)
                    print(Style.info("Setting up shared-folder provisioning..."))
                    try injectOrFail(label: "Shared-folder provisioning") {
                        try SharedFolderProvisioner.provision(
                            script: scriptURL,
                            bundle: bundle
                        )
                        let watcherScript = try ScriptFile.writeToCache(
                            script: SharedFolderProvisioner.watcherInstallScript(),
                            fileName: "install-watcher.sh"
                        )
                        // DiskInjector copies the script bytes into the
                        // VM's disk image — once injected, the host-side
                        // copy is no longer needed and becomes just
                        // another potential on-disk secret surface.
                        defer {
                            do {
                                try ScriptFile.cleanup(scriptURL: watcherScript)
                            } catch {
                                print(Style.dim("Watcher script cleanup failed: \(error.localizedDescription)"))
                            }
                        }
                        try DiskInjector.inject(script: watcherScript, into: bundle)
                    }
                    print(Style.success("✓ Script placed in shared folder. Watcher daemon injected."))

                case .ssh:
                    break
                }
            }

            let modeLabel = recovery ? " in Recovery mode" : ""
            print(Style.info("Starting VM '\(name)'\(modeLabel)..."))

            let vm = try VirtualMachine(bundle: bundle)

            guard let underlyingVM = vm.vzVM else {
                print(Style.error("✗ Failed to create virtual machine instance."))
                throw ExitCode.failure
            }

            // Write-then-verify closes the TOCTOU gap where two processes
            // could both pass a capacity check before either writes its PID.
            do {
                try PIDFile.writeAndEnsureCapacity(
                    bundleURL: bundleURL,
                    vmDirectory: SpooktacularPaths.vms
                )
            } catch let error as CapacityError {
                print(Style.error("✗ \(error.localizedDescription)"))
                if let recovery = error.recoverySuggestion {
                    print(Style.dim("  \(recovery)"))
                }
                throw ExitCode.failure
            }

            let isEphemeral = ephemeral
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    let sigName = sig == SIGTERM ? "SIGTERM" : "SIGINT"
                    print("\nReceived \(sigName) — stopping VM '\(name)'...")
                    Task { @MainActor in
                        try? await vm.stop(graceful: false)
                        cleanupAfterStop(
                            bundleURL: bundleURL,
                            name: name,
                            ephemeral: isEphemeral
                        )
                        Foundation.exit(0)
                    }
                }
                source.resume()
            }

            // SIGUSR1 = "suspend to disk, then exit." Sent by
            // `spook suspend <name>`. Kept distinct from SIGTERM
            // so rapid-tapping `spook stop` never accidentally
            // leaves a SavedState.vzstate around that would
            // override the next cold-boot intent.
            signal(SIGUSR1, SIG_IGN)
            let suspendSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            suspendSource.setEventHandler {
                print("\nReceived SIGUSR1 — suspending VM '\(name)'...")
                Task { @MainActor in
                    do {
                        try await vm.suspend()
                        PIDFile.remove(from: bundleURL)
                        Foundation.exit(0)
                    } catch {
                        print("Suspend failed: \(error.localizedDescription) — falling back to stop.")
                        try? await vm.stop(graceful: false)
                        cleanupAfterStop(
                            bundleURL: bundleURL,
                            name: name,
                            ephemeral: isEphemeral
                        )
                        Foundation.exit(1)
                    }
                }
            }
            suspendSource.resume()

            // Attach the display window BEFORE starting the VM
            // so `VZVirtualMachineView.virtualMachine` is bound
            // when the guest GPU first negotiates its scanout
            // mode.  Apple's canonical samples (Running GUI
            // Linux in a VM on a Mac / Running macOS in a VM on
            // Apple silicon) do this in the same order.  For
            // `--headless` we skip the window entirely and
            // monitor the state stream directly.
            let vmWindow: VMWindow? = headless
                ? nil
                : VMWindow.attach(name: name, virtualMachine: underlyingVM)

            if recovery {
                // Recovery must cold-boot — a saved-state file
                // would collide with the recovery-partition boot
                // options. Wipe it defensively.
                try? FileManager.default.removeItem(at: bundle.savedStateURL)
                let options = VZMacOSVirtualMachineStartOptions()
                options.startUpFromMacOSRecovery = true
                nonisolated(unsafe) let unsafeVM = underlyingVM
                try await unsafeVM.start(options: options)
            } else if let marker = bundle.metadata.pendingProvisioning {
                // First boot of a VM created with native provisioning
                // (`--remote-desktop`, `--openclaw`, `--user-data` —
                // anything that injected a first-boot.sh at create but
                // did not boot then). On macOS 27 the guest would
                // otherwise stall at an undriven Setup Assistant, so
                // drive it via `VZMacGuestProvisioningOptions`.
                //
                // The marker in metadata is NON-SECRET; the account
                // password lives only in the System Keychain, written at
                // create and keyed by the VM UUID. Read it back here.
                let storedPassword: String?
                do {
                    storedPassword = try ProvisioningPasswordStore.readPassword(forVM: bundle.metadata.id)
                } catch {
                    // A Keychain read error (not a plain miss) — degrade
                    // to a bare boot rather than crash. The account just
                    // won't be auto-provisioned.
                    print(Style.dim("Could not read provisioning password from Keychain: \(error.localizedDescription)"))
                    storedPassword = nil
                }

                if let password = storedPassword {
                    let spec = marker.spec(password: password)
                    try await vm.startOrResume(guestProvisioning: spec)
                    print(Style.success("✓ Applied first-boot provisioning for account '\(marker.username)'."))

                    // Start succeeded — erase the transient password from
                    // the Keychain and clear the marker so a later start
                    // doesn't re-carry either (the framework ignores the
                    // options after first boot anyway). Neither cleanup
                    // failure may turn an already-successful boot into a
                    // reported error.
                    do {
                        try ProvisioningPasswordStore.deletePassword(forVM: bundle.metadata.id)
                    } catch {
                        print(Style.dim("Could not delete provisioning password from Keychain: \(error.localizedDescription)"))
                    }
                    do {
                        var meta = bundle.metadata
                        meta.pendingProvisioning = nil
                        try VirtualMachineBundle.writeMetadata(meta, to: bundleURL)
                    } catch {
                        print(Style.dim("Could not clear pending provisioning from metadata: \(error.localizedDescription)"))
                    }
                } else {
                    // Marker present but no Keychain password — the item
                    // lives in the root-owned System keychain, so a non-root
                    // `start` (or a VM created on another host/user) can't
                    // read it. Don't crash: boot normally. The marker is left
                    // in place so a `sudo spook start` on the originating host
                    // can still apply it.
                    print(Style.warning("⚠ First-boot provisioning is pending, but its password isn't readable here."))
                    print(Style.dim("  Run `sudo spook start \(name)` if this host created the VM — the password is in the"))
                    print(Style.dim("  root-owned System keychain. Starting without provisioning; on macOS 27 you may then"))
                    print(Style.dim("  need to complete Setup Assistant in the VM window."))
                    try await vm.startOrResume()
                }
            } else {
                // `startOrResume` transparently restores from
                // `SavedState.vzstate` when one exists (the
                // "close the laptop" flow). Falls through to a
                // cold boot if restore fails so the user never
                // gets stuck.
                try await vm.startOrResume()
            }

            print(Style.success("✓ VM '\(name)' is running."))

            if let scriptPath = userData {
                Style.field("User-data", scriptPath)
                Style.field("Provision", provision.label)

                switch provision {
                case .diskInject, .sharedFolder:
                    // Handled pre-boot above.
                    break

                case .ssh:
                    let scriptURL = URL(filePath: scriptPath.expandingTilde)
                    guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                        print(Style.error("✗ User-data script not found at '\(scriptPath)'."))
                        print(Style.dim("  Verify the file path exists and is readable."))
                        throw ExitCode.failure
                    }

                    if let macAddress = bundle.spec.macAddress {
                        print(Style.info("Provisioning via SSH..."))
                        try await VMProvisioner.provisionViaSSH(
                            macAddress: macAddress,
                            script: scriptURL,
                            user: sshUser,
                            key: sshKey,
                            timeout: 120
                        )
                        print(Style.success("✓ User-data script completed."))
                    } else {
                        print(Style.warning("No MAC address configured. Cannot resolve IP for SSH provisioning."))
                        print(Style.dim("Set a MAC address with 'spook set \(name) --mac-address <addr>' for automatic IP resolution."))
                    }

                }
            }

            if ephemeral {
                print(Style.yellow("⟳ Ephemeral mode: VM will be destroyed when it stops."))
            }

            if let vmWindow {
                let isEphemeralCapture = ephemeral
                let nameCapture = name
                let bundleCapture = bundleURL

                await vmWindow.runEventLoop(
                    stateStream: vm.stateStream,
                    onStop: {
                        cleanupAfterStop(
                            bundleURL: bundleCapture,
                            name: nameCapture,
                            ephemeral: isEphemeralCapture
                        )
                    }
                )
            } else {
                print(Style.dim("Running headless. Press Ctrl+C to stop."))

                for await state in vm.stateStream {
                    if state == .stopped || state == .error {
                        break
                    }
                }

                cleanupAfterStop(
                    bundleURL: bundleURL,
                    name: name,
                    ephemeral: ephemeral
                )
            }
        }

        private func requireScript(at url: URL, path: String) throws {
            guard FileManager.default.fileExists(atPath: url.path) else {
                print(Style.error("✗ User-data script not found at '\(path)'."))
                print(Style.dim("  Verify the file path exists and is readable."))
                throw ExitCode.failure
            }
        }

        private func injectOrFail(label: String, _ work: () throws -> Void) throws {
            do {
                try work()
            } catch {
                print(Style.error("✗ \(label) failed: \(error.localizedDescription)"))
                if let localizedError = error as? LocalizedError,
                   let recovery = localizedError.recoverySuggestion {
                    print(Style.dim("  \(recovery)"))
                }
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - Cleanup

/// Removes the PID file and, for ephemeral VMs, deletes the bundle.
///
/// Called from both the state-stream observer and the signal handler
/// to avoid duplicating cleanup logic.
@MainActor
private func cleanupAfterStop(bundleURL: URL, name: String, ephemeral: Bool) {
    PIDFile.remove(from: bundleURL)
    if ephemeral {
        try? FileManager.default.removeItem(at: bundleURL)
        print("Ephemeral VM '\(name)' destroyed.")
    }
}

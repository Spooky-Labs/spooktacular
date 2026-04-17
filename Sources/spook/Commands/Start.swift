import AppKit
import ArgumentParser
import Foundation
import SpooktacularKit
@preconcurrency import Virtualization

extension Spook {

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
                disk-inject, ssh, agent, or shared-folder.
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

                case .ssh, .agent:
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

            if recovery {
                let options = VZMacOSVirtualMachineStartOptions()
                options.startUpFromMacOSRecovery = true
                nonisolated(unsafe) let unsafeVM = underlyingVM
                try await unsafeVM.start(options: options)
            } else {
                try await vm.start()
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

                case .agent:
                    let scriptURL = URL(filePath: scriptPath.expandingTilde)
                    guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                        print(Style.error("✗ User-data script not found at '\(scriptPath)'."))
                        print(Style.dim("  Verify the file path exists and is readable."))
                        throw ExitCode.failure
                    }

                    var fallbackIP: String?
                    if let macAddress = bundle.spec.macAddress {
                        fallbackIP = try? await IPResolver.resolveIP(macAddress: macAddress)
                    }

                    print(Style.info("Provisioning via guest agent (vsock)..."))
                    do {
                        try await VsockProvisioner.provision(
                            virtualMachine: vm,
                            script: scriptURL,
                            fallbackIP: fallbackIP,
                            sshUser: sshUser,
                            sshKey: sshKey
                        )
                        print(Style.success("✓ User-data script completed."))
                    } catch {
                        print(Style.error("✗ Agent provisioning failed: \(error.localizedDescription)"))
                        if let localizedError = error as? LocalizedError,
                           let recovery = localizedError.recoverySuggestion {
                            print(Style.dim("  \(recovery)"))
                        }
                        throw ExitCode.failure
                    }

                }
            }

            if ephemeral {
                print(Style.yellow("⟳ Ephemeral mode: VM will be destroyed when it stops."))
            }

            if !headless {
                let isEphemeralCapture = ephemeral
                let nameCapture = name
                let bundleCapture = bundleURL

                await presentVMWindow(
                    name: name,
                    virtualMachine: underlyingVM,
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

import ArgumentParser
import Foundation
import SpooktacularKit
import Virtualization
import AppKit

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

        @MainActor
        func run() async throws {
            let bundleURL = try Paths.requireBundle(for: name)

            // Enforce the 2-VM concurrency limit before proceeding.
            try Paths.ensureDirectories()
            do {
                try CapacityCheck.ensureCapacity(in: Paths.vms)
            } catch let error as CapacityError {
                print(Style.error("✗ \(error.localizedDescription)"))
                if let recovery = error.recoverySuggestion {
                    print(Style.dim("  \(recovery)"))
                }
                throw ExitCode.failure
            }

            // Check if this specific VM is already running.
            if PIDFile.isRunning(bundleURL: bundleURL) {
                print(Style.error("✗ VM '\(name)' is already running."))
                throw ExitCode.failure
            }

            let bundle = try VirtualMachineBundle.load(from: bundleURL)

            // Pre-boot provisioning: modes that write to the guest disk
            // or shared folder while the VM is stopped.
            if let scriptPath = userData {
                let scriptURL = URL(fileURLWithPath:
                    NSString(string: scriptPath).expandingTildeInPath
                )

                switch provision {
                case .diskInject:
                    guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                        print(Style.error("✗ User-data script not found at '\(scriptPath)'."))
                        print(Style.dim("  Verify the file path exists and is readable."))
                        throw ExitCode.failure
                    }
                    print(Style.info("Injecting user-data script into guest disk..."))
                    do {
                        try DiskInjector.inject(script: scriptURL, into: bundle)
                        print(Style.success("✓ Script injected. It will run automatically on boot."))
                    } catch {
                        print(Style.error("✗ Disk injection failed: \(error.localizedDescription)"))
                        if let localizedError = error as? LocalizedError,
                           let recovery = localizedError.recoverySuggestion {
                            print(Style.dim("  \(recovery)"))
                        }
                        throw ExitCode.failure
                    }

                case .sharedFolder:
                    guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                        print(Style.error("✗ User-data script not found at '\(scriptPath)'."))
                        print(Style.dim("  Verify the file path exists and is readable."))
                        throw ExitCode.failure
                    }
                    print(Style.info("Setting up shared-folder provisioning..."))
                    do {
                        // Place script in shared folder for the watcher daemon.
                        try SharedFolderProvisioner.provision(
                            script: scriptURL,
                            bundle: bundle
                        )
                        // Inject the watcher daemon into the disk so it works
                        // on any VM, even without pre-installed watchers.
                        let watcherScript = try ScriptFile.writeToTempDirectory(
                            script: SharedFolderProvisioner.watcherInstallScript(),
                            fileName: "install-watcher.sh"
                        )
                        try DiskInjector.inject(script: watcherScript, into: bundle)
                        print(Style.success("✓ Script placed in shared folder. Watcher daemon injected."))
                    } catch {
                        print(Style.error("✗ Shared-folder provisioning failed: \(error.localizedDescription)"))
                        if let localizedError = error as? LocalizedError,
                           let recovery = localizedError.recoverySuggestion {
                            print(Style.dim("  \(recovery)"))
                        }
                        throw ExitCode.failure
                    }

                case .ssh, .agent:
                    // These modes run after boot. Nothing to do pre-boot.
                    break
                }
            }

            let modeLabel = recovery ? " in Recovery mode" : ""
            print("Starting VM '\(name)'\(modeLabel)...")

            let vm = try VirtualMachine(bundle: bundle)

            guard let underlyingVM = vm.vzVM else {
                print(Style.error("✗ Failed to create virtual machine instance."))
                throw ExitCode.failure
            }

            // Write PID file so other commands can find this process.
            try PIDFile.write(to: bundleURL)

            // Graceful shutdown on SIGTERM and SIGINT (Ctrl+C).
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    let sigName = sig == SIGTERM ? "SIGTERM" : "SIGINT"
                    print("\nReceived \(sigName) — stopping VM '\(name)'...")
                    Task { @MainActor in
                        try? await vm.stop(graceful: false)
                        PIDFile.remove(from: bundleURL)
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

            // Post-boot provisioning: handle modes that run after the VM starts.
            if let scriptPath = userData {
                Style.field("User-data", scriptPath)
                Style.field("Provision", provision.label)

                switch provision {
                case .diskInject:
                    // Already handled above (before vm.start). The script
                    // was injected into the disk and will run via launchd.
                    break

                case .ssh:
                    let scriptURL = URL(fileURLWithPath:
                        NSString(string: scriptPath).expandingTildeInPath
                    )
                    guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                        print(Style.error("✗ User-data script not found at '\(scriptPath)'."))
                        print(Style.dim("  Verify the file path exists and is readable."))
                        throw ExitCode.failure
                    }

                    // Resolve the VM's IP to connect via SSH.
                    if let macAddress = bundle.spec.macAddress {
                        print("Resolving VM IP address...")
                        if let ip = try await IPResolver.resolveIP(macAddress: macAddress) {
                            print("Waiting for SSH on \(ip)...")
                            try await SSHExecutor.waitForSSH(ip: ip)

                            print("Executing user-data script...")
                            try await SSHExecutor.execute(
                                script: scriptURL,
                                on: ip,
                                user: sshUser,
                                key: sshKey
                            )
                            print(Style.success("✓ User-data script completed."))
                        } else {
                            print(Style.warning("Could not resolve VM IP. Skipping user-data execution."))
                            print(Style.dim("Ensure the VM has booted and obtained a network address."))
                        }
                    } else {
                        print(Style.warning("No MAC address configured. Cannot resolve IP for SSH provisioning."))
                        print(Style.dim("Set a MAC address with 'spook set \(name) --mac-address <addr>' for automatic IP resolution."))
                    }

                case .agent:
                    let scriptURL = URL(fileURLWithPath:
                        NSString(string: scriptPath).expandingTildeInPath
                    )
                    guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                        print(Style.error("✗ User-data script not found at '\(scriptPath)'."))
                        print(Style.dim("  Verify the file path exists and is readable."))
                        throw ExitCode.failure
                    }

                    // Resolve the VM's IP for SSH fallback if the agent is not installed.
                    var fallbackIP: String?
                    if let macAddress = bundle.spec.macAddress {
                        fallbackIP = try? await IPResolver.resolveIP(macAddress: macAddress)
                    }

                    print("Provisioning via guest agent (vsock)...")
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

                case .sharedFolder:
                    // Already handled above (before vm.start). The script
                    // was placed in the shared folder and the watcher daemon
                    // was injected into the disk. It will run via launchd.
                    break
                }
            }

            if !headless {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)

                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1200),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "Spooktacular — \(name)"
                window.center()

                let vmView = VZVirtualMachineView()
                vmView.virtualMachine = underlyingVM
                vmView.capturesSystemKeys = true
                if #available(macOS 14.0, *) {
                    vmView.automaticallyReconfiguresDisplay = true
                }
                window.contentView = vmView
                window.makeKeyAndOrderFront(nil)

                app.activate(ignoringOtherApps: true)
                print(Style.dim("Press Ctrl+C to stop the VM."))
            } else {
                print(Style.dim("Running headless. Press Ctrl+C to stop."))
            }

            // Block until the VM stops or the process is interrupted.
            // Listen to the state stream instead of leaking a continuation.
            for await state in vm.stateStream {
                if state == .stopped || state == .error {
                    break
                }
            }

            // Clean up PID file when VM stops normally.
            PIDFile.remove(from: bundleURL)
        }
    }
}

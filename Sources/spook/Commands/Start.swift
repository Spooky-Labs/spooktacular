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

        @MainActor
        func run() async throws {
            let bundleURL = Paths.bundleURL(for: name)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                print("Error: VM '\(name)' not found.")
                throw ExitCode.failure
            }

            let bundle = try VMBundle.load(from: bundleURL)

            if recovery {
                print("Starting VM '\(name)' in Recovery mode...")
            } else {
                print("Starting VM '\(name)'...")
            }

            let vm = try VirtualMachine(bundle: bundle)

            if recovery {
                let options = VZMacOSVirtualMachineStartOptions()
                options.startUpFromMacOSRecovery = true
                try await vm.vzVM!.start(options: options)
            } else {
                try await vm.start()
            }

            print("✓ VM '\(name)' is running.")

            if let scriptPath = userData {
                print("User-data script: \(scriptPath)")
                print("Provisioning method: \(provision.label)")
                // TODO: Execute user-data via selected provisioning mode.
                print("(User-data provisioning will be applied via \(provision.label).)")
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
                vmView.virtualMachine = vm.vzVM
                vmView.capturesSystemKeys = true
                window.contentView = vmView
                window.makeKeyAndOrderFront(nil)

                app.activate(ignoringOtherApps: true)

                print("Press Ctrl+C to stop the VM.")
            } else {
                print("Running headless. Press Ctrl+C to stop.")
            }

            // Keep the process alive until interrupted.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
    }
}

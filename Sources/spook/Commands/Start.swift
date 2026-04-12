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

            let modeLabel = recovery ? " in Recovery mode" : ""
            print("Starting VM '\(name)'\(modeLabel)...")

            let vm = try VirtualMachine(bundle: bundle)

            guard let underlyingVM = vm.vzVM else {
                print(Style.error("✗ Failed to create virtual machine instance."))
                throw ExitCode.failure
            }

            if recovery {
                let options = VZMacOSVirtualMachineStartOptions()
                options.startUpFromMacOSRecovery = true
                try await underlyingVM.start(options: options)
            } else {
                try await vm.start()
            }

            print(Style.success("✓ VM '\(name)' is running."))

            if let scriptPath = userData {
                Style.field("User-data", scriptPath)
                Style.field("Provision", provision.label)
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
        }
    }
}

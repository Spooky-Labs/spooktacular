import AppKit
import Virtualization
import SpooktacularKit

/// Presents a VM in a native macOS window and runs the AppKit event loop.
///
/// Creates an `NSWindow` containing a `VZVirtualMachineView`,
/// monitors the VM's state stream, and terminates the application
/// when the VM stops or encounters an error. The caller can
/// perform cleanup (PID file removal, ephemeral deletion) in
/// the provided `onStop` closure.
///
/// - Parameters:
///   - name: The VM name, displayed in the window title.
///   - virtualMachine: The underlying `VZVirtualMachine` to display.
///   - stateStream: An `AsyncStream` of VM state changes.
///   - onStop: A closure called when the VM stops or errors,
///     before the application terminates.
@MainActor
func presentVMWindow(
    name: String,
    virtualMachine: VZVirtualMachine,
    stateStream: AsyncStream<VirtualMachineState>,
    onStop: @MainActor @Sendable @escaping () -> Void
) async {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1200),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Spooktacular \u{2014} \(name)"
    window.center()

    let vmView = VZVirtualMachineView()
    vmView.virtualMachine = virtualMachine
    vmView.capturesSystemKeys = true
    if #available(macOS 14.0, *) {
        vmView.automaticallyReconfiguresDisplay = true
    }
    window.contentView = vmView
    window.makeKeyAndOrderFront(nil)

    app.activate()
    print(Style.dim("Press Ctrl+C to stop the VM."))

    // Monitor state in background, terminate app when VM stops.
    Task { @MainActor in
        for await state in stateStream {
            if state == .stopped || state == .error {
                break
            }
        }
        onStop()
        NSApp.terminate(nil)
    }

    app.run()
}

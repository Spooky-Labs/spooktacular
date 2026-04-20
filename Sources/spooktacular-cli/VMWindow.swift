import AppKit
import Virtualization
import SpooktacularKit

/// Host-side window that presents a `VZVirtualMachine` in a
/// native macOS window backed by `VZVirtualMachineView`.
///
/// Construction is split into two phases to match Apple's
/// canonical ordering from the "Running GUI Linux in a VM on
/// a Mac" and "Running macOS in a VM on Apple silicon"
/// samples: the view must own a reference to the
/// `VZVirtualMachine` **before** `start()` fires so the
/// framework has a scanout consumer attached as soon as the
/// guest GPU negotiates its mode.
///
/// 1. ``attach(name:virtualMachine:)`` — build the window,
///    create `VZVirtualMachineView`, assign the VM, order
///    the window front.  Runs synchronously on the main
///    actor; no event loop yet.  Call this *before*
///    `VZVirtualMachine.start()`.
/// 2. ``runEventLoop(stateStream:onStop:)`` — primes
///    AppKit via `NSApplication.run()`, concurrently
///    watches the VM's state stream via an `async let`
///    child task, and terminates the app when the VM
///    transitions to `.stopped` or `.error`.  Call this
///    *after* the VM has started.
///
/// Reference:
/// - [VZVirtualMachineView.virtualMachine](https://developer.apple.com/documentation/virtualization/vzvirtualmachineview/virtualmachine)
/// - [Running GUI Linux in a virtual machine on a Mac — Start the VM](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac)
@MainActor
final class VMWindow {
    let window: NSWindow
    let view: VZVirtualMachineView

    private init(window: NSWindow, view: VZVirtualMachineView) {
        self.window = window
        self.view = view
    }

    /// Builds the window and attaches the VM to a fresh
    /// `VZVirtualMachineView`.  Safe to call before the VM
    /// starts; the view latches onto the VM's graphics
    /// devices as soon as they come online.
    static func attach(
        name: String,
        virtualMachine: VZVirtualMachine
    ) -> VMWindow {
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

        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        return VMWindow(window: window, view: view)
    }

    /// Starts `NSApplication.run()` and suspends until the VM
    /// transitions to `.stopped` or `.error`.
    ///
    /// `async let` creates a structured child task that
    /// runs ``watchForTerminalState(_:)`` concurrently with
    /// the Cocoa event loop.  Because both the child task
    /// and `NSApp.run()` run on the main actor, they share
    /// the main-queue runloop: AppKit dispatches events,
    /// and the child's `for await` continuations are
    /// resumed on the same queue.  When the child sees a
    /// terminal state it calls `NSApp.terminate(nil)`,
    /// which unblocks `NSApp.run()`.  If the runloop exits
    /// for any other reason (Cmd-Q, signal handler), the
    /// language cancels the `async let` child at scope
    /// exit — no manual cleanup required.
    func runEventLoop(
        stateStream: AsyncStream<VirtualMachineState>,
        onStop: @MainActor @Sendable () -> Void
    ) async {
        NSApp.activate()
        print(Style.dim("Press Ctrl+C to stop the VM."))

        async let _: Void = watchForTerminalState(stateStream)
        NSApp.run()
        onStop()
    }

    /// Consumes the VM's state stream; on the first
    /// `.stopped` or `.error` transition, posts
    /// `NSApp.terminate(nil)` to unblock the event loop.
    private func watchForTerminalState(
        _ stateStream: AsyncStream<VirtualMachineState>
    ) async {
        for await state in stateStream {
            if state == .stopped || state == .error {
                NSApp.terminate(nil)
                return
            }
        }
    }
}

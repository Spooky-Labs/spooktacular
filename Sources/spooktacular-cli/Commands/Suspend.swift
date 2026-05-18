import ArgumentParser
import Darwin
import Foundation
import SpooktacularKit

extension Spooktacular {

    /// Suspends a running virtual machine to disk.
    ///
    /// Signals the `spook start` daemon process to pause the VM,
    /// write a `SavedState.vzstate` file into the bundle via
    /// Apple's `VZVirtualMachine.saveMachineStateTo(url:)`, then
    /// exit cleanly. The next `spook start <name>` restores from
    /// the saved-state file — the user picks up with every app
    /// open and every document unsaved, exactly where they left
    /// off.
    ///
    /// Distinct from `spook stop` (cold shutdown) and
    /// `spook snapshot save` (named, keep-forever checkpoint).
    /// Suspend is the "close the laptop" gesture: transient,
    /// consumed by the next start.
    ///
    /// Implemented by sending `SIGUSR1` to the owning daemon
    /// PID. The daemon's signal handler calls
    /// `VirtualMachine.suspend()` — which itself wraps Apple's
    /// pause + save + stop sequence — and then removes the PID
    /// file.
    struct Suspend: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Suspend a running VM to disk.",
            discussion: """
                Saves the VM's full runtime state (memory, CPU, \
                device state) to a SavedState.vzstate file in the \
                bundle, then shuts the VM down. The next 'spook \
                start \(Self.placeholderName)' resumes from that \
                file instead of cold-booting — every app remains \
                open, every unsaved document preserved.

                Use 'spook discard-suspend \(Self.placeholderName)' \
                to delete the saved-state file without resuming.

                REQUIRES macOS 14+ on the host for \
                saveMachineStateTo / restoreMachineStateFrom.

                EXAMPLES:
                  spook suspend my-vm
                """
        )

        private static let placeholderName = "<name>"

        @Argument(help: "Name of the VM to suspend.")
        var name: String

        @Option(
            help: """
                Seconds to wait for the daemon to write the \
                saved-state file and exit. macOS 14's save path \
                takes 1–3 s per GB of guest memory on NVMe.
                """
        )
        var timeout: Int = 60

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            guard let pid = PIDFile.read(from: bundleURL) else {
                print(Style.dim("VM '\(name)' is not running (no PID file found)."))
                return
            }

            guard PIDFile.isProcessAlive(pid) else {
                print(Style.dim("VM '\(name)' is not running (stale PID file, process \(pid) exited)."))
                PIDFile.remove(from: bundleURL)
                return
            }

            print(Style.info("Sending SIGUSR1 to VM '\(name)' (PID \(pid))..."))
            let result = kill(pid, SIGUSR1)
            if result != 0 {
                let errorCode = errno
                print(Style.error("✗ Failed to signal PID \(pid): errno \(errorCode)"))
                throw ExitCode.failure
            }

            // Poll until the daemon has written the saved-state
            // file and exited. A 60 s default covers large guests
            // on slow disks; the polling granularity matches
            // Stop.swift so the two commands feel consistent.
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                if !PIDFile.isProcessAlive(pid) {
                    let bundle = try? VirtualMachineBundle.load(from: bundleURL)
                    if bundle?.hasSavedState == true {
                        print(Style.success("✓ VM '\(name)' suspended."))
                        print(Style.dim("  Run 'spook start \(name)' to resume where it left off."))
                        return
                    } else {
                        print(Style.warning("Daemon exited without writing a saved-state file."))
                        print(Style.dim("  The VM is stopped; next start will cold-boot."))
                        return
                    }
                }
            }
            print(Style.warning("Daemon has not exited within \(timeout) s."))
            print(Style.dim("  Re-run with --timeout for a longer window, or 'spook stop \(name) --force' to abort."))
            throw ExitCode.failure
        }
    }

    /// Discards a previously-saved suspend file without
    /// resuming, forcing the next `spook start` to cold-boot.
    ///
    /// Only meaningful when the VM is stopped. If the VM is
    /// running, use `spook stop` or `spook suspend` instead.
    struct DiscardSuspend: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "discard-suspend",
            abstract: "Delete the SavedState.vzstate file for a stopped VM.",
            discussion: """
                Removes any suspend file left behind by a previous \
                'spook suspend'. The next 'spook start <name>' \
                then cold-boots regardless.

                No-op when the VM is running or when no saved-state \
                file exists — exits 0 with a short explanation so \
                it's safe to call from automation.

                EXAMPLES:
                  spook discard-suspend my-vm
                """
        )

        @Argument(help: "Name of the VM whose saved-state to discard.")
        var name: String

        func run() async throws {
            let bundleURL = try requireBundle(for: name)

            if let pid = PIDFile.read(from: bundleURL), PIDFile.isProcessAlive(pid) {
                print(Style.error("✗ VM '\(name)' is running. Stop or suspend it first."))
                throw ExitCode.failure
            }

            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            guard bundle.hasSavedState else {
                print(Style.dim("VM '\(name)' has no saved-state file. Nothing to discard."))
                return
            }

            try FileManager.default.removeItem(at: bundle.savedStateURL)
            print(Style.success("✓ Saved-state file for '\(name)' discarded."))
            print(Style.dim("  Next 'spook start \(name)' will cold-boot."))
        }
    }
}

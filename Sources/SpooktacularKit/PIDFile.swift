import Foundation
import os

/// Manages PID files for tracking running virtual machines.
///
/// Each running VM writes a PID file at
/// `~/.spooktacular/vms/<name>.vm/pid`. The file contains the
/// process ID of the `spook start` process that owns the VM.
/// Other commands (`stop`, `list`, `ip`) read the PID file to
/// determine whether a VM is running and to signal the process.
///
/// ## PID File Lifecycle
///
/// 1. `spook start` writes the PID file before booting the VM.
/// 2. `spook stop` reads the PID file and sends SIGTERM.
/// 3. `spook start` installs a SIGTERM handler that gracefully
///    stops the VM, removes the PID file, and exits.
/// 4. If the process crashes, the PID file becomes stale.
///    ``isProcessAlive(_:)`` detects stale PID files by checking
///    whether the recorded process is still running.
///
/// ## Thread Safety
///
/// All methods are static and operate on the file system. They
/// are safe to call from any thread. The PID file is a plain
/// text file containing a single integer, so reads and writes
/// are effectively atomic at the file-system level.
public enum PIDFile {

    /// The file name used for PID files inside VM bundle directories.
    public static let fileName = "pid"

    // MARK: - Write and Remove

    /// Writes the current process's PID to the VM bundle directory.
    ///
    /// Creates a file named `pid` inside the bundle directory
    /// containing the current process ID as a decimal string.
    ///
    /// - Parameter bundleURL: The file URL of the `.vm` bundle
    ///   directory (e.g., `~/.spooktacular/vms/my-vm.vm`).
    /// - Throws: An error if the file cannot be written.
    public static func write(to bundleURL: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidURL = bundleURL.appendingPathComponent(fileName)
        try Data("\(pid)".utf8).write(to: pidURL, options: .atomic)
        Log.vm.info("Wrote PID file: \(pid) → \(pidURL.lastPathComponent, privacy: .public)")
    }

    /// Removes the PID file from the VM bundle directory.
    ///
    /// Silently succeeds if the PID file does not exist.
    ///
    /// - Parameter bundleURL: The file URL of the `.vm` bundle
    ///   directory.
    public static func remove(from bundleURL: URL) {
        let pidURL = bundleURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: pidURL)
        Log.vm.info("Removed PID file from \(bundleURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Terminate

    /// Sends `SIGTERM` to the process owning the VM, waits for it to
    /// exit, escalates to `SIGKILL` if needed, and removes the PID file.
    ///
    /// This method centralizes the "stop a VM process" pattern used by
    /// `spook delete --force` and `spook stop --force`. It guarantees
    /// the PID file is always cleaned up, even if the process was
    /// already dead.
    ///
    /// - Parameters:
    ///   - bundleURL: The file URL of the `.vm` bundle directory.
    ///   - gracePeriod: Maximum time (in seconds) to wait after
    ///     `SIGTERM` before escalating to `SIGKILL`. Defaults to 10.
    public static func terminate(bundleURL: URL, gracePeriod: TimeInterval = 10) async {
        guard let pid = read(from: bundleURL), isProcessAlive(pid) else {
            remove(from: bundleURL)
            return
        }

        Log.vm.info("Sending SIGTERM to PID \(pid) for \(bundleURL.lastPathComponent, privacy: .public)")
        kill(pid, SIGTERM)

        // Poll until the process exits or the grace period expires.
        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline && isProcessAlive(pid) {
            try? await Task.sleep(for: .milliseconds(500))
        }

        if isProcessAlive(pid) {
            Log.vm.warning("PID \(pid) did not exit within \(Int(gracePeriod))s, sending SIGKILL")
            kill(pid, SIGKILL)
        }

        remove(from: bundleURL)
    }

    // MARK: - Read and Query

    /// Reads the PID from a VM bundle's PID file.
    ///
    /// - Parameter bundleURL: The file URL of the `.vm` bundle
    ///   directory.
    /// - Returns: The process ID recorded in the PID file, or
    ///   `nil` if the file does not exist or cannot be parsed.
    public static func read(from bundleURL: URL) -> pid_t? {
        let pidURL = bundleURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: pidURL),
              let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(string)
        else {
            Log.vm.debug("No PID file found in \(bundleURL.lastPathComponent, privacy: .public)")
            return nil
        }
        Log.vm.debug("Read PID \(pid) from \(bundleURL.lastPathComponent, privacy: .public)")
        return pid
    }

    /// Checks whether the given process ID refers to a running process.
    ///
    /// Uses `kill(pid, 0)` to probe the process without sending a
    /// signal. Returns `true` if the process exists and is owned
    /// by the current user (or the current user is root).
    ///
    /// - Parameter pid: The process ID to check.
    /// - Returns: `true` if the process is alive, `false` otherwise.
    public static func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Checks whether a VM bundle has an active (running) process.
    ///
    /// Reads the PID file and verifies the recorded process is
    /// still alive. Returns `false` if there is no PID file or
    /// the recorded process has exited. When the recorded process
    /// is dead, the stale PID file is proactively removed so it
    /// does not interfere with future capacity checks.
    ///
    /// - Parameter bundleURL: The file URL of the `.vm` bundle
    ///   directory.
    /// - Returns: `true` if the VM has a PID file pointing to a
    ///   live process.
    public static func isRunning(bundleURL: URL) -> Bool {
        guard let pid = read(from: bundleURL) else { return false }
        let alive = isProcessAlive(pid)
        if !alive {
            Log.vm.debug("Stale PID \(pid) in \(bundleURL.lastPathComponent, privacy: .public) — removing stale PID file")
            remove(from: bundleURL)
        }
        return alive
    }

    // MARK: - Atomic Capacity Reservation

    /// Writes the PID file and then verifies the VM concurrency
    /// limit has not been exceeded.
    ///
    /// This method closes the TOCTOU (time-of-check-to-time-of-use)
    /// gap that exists when capacity is checked *before* writing the
    /// PID file. By writing first, this process's VM is visible to
    /// any concurrent starter that also calls this method. If the
    /// resulting count exceeds the limit the PID file is removed
    /// and a ``CapacityError/limitReached(running:)`` error is thrown.
    ///
    /// - Parameters:
    ///   - bundleURL: The file URL of the `.vm` bundle directory.
    ///   - vmDirectory: The parent directory containing all `.vm`
    ///     bundles (typically `~/.spooktacular/vms/`).
    /// - Throws: ``CapacityError/limitReached(running:)`` if the
    ///   host is already at the concurrent VM limit.
    public static func writeAndEnsureCapacity(bundleURL: URL, vmDirectory: URL) throws {
        try write(to: bundleURL)
        let running = CapacityCheck.runningVMs(in: vmDirectory)
        if running.count > CapacityCheck.maxConcurrentVMs {
            remove(from: bundleURL)
            throw CapacityError.limitReached(running: running)
        }
    }
}

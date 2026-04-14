import Foundation
import SpookCore

/// Enforces the Apple Silicon concurrent VM limit.
///
/// The macOS Virtualization framework on Apple Silicon supports
/// at most 2 concurrent virtual machines per host. Attempting to
/// start a third VM causes a kernel-level failure that is
/// difficult to diagnose. This module checks the limit proactively
/// and provides a clear error message.
///
/// ## How It Works
///
/// ``CapacityCheck`` scans all `.vm` bundles in a given directory
/// for active PID files (see ``PIDFile``). A bundle counts as
/// "running" if it has a PID file whose recorded process is still
/// alive.
///
/// ```swift
/// try CapacityCheck.ensureCapacity(in: vmDirectory)
/// ```
///
/// If 2 or more VMs are already running, the method throws a
/// ``CapacityError/limitReached(running:)`` error.
public enum CapacityCheck {

    /// The maximum number of concurrent VMs allowed by Apple Silicon.
    ///
    /// This limit is enforced by the macOS kernel's Hypervisor
    /// framework. The Virtualization framework does not surface
    /// this limit in its API, so we enforce it in userspace.
    public static let maxConcurrentVMs = 2

    /// Returns the names of all currently running VMs in the
    /// given directory.
    ///
    /// Scans all `.vm` bundle directories for PID files and checks
    /// whether the recorded process is alive.
    ///
    /// - Parameters:
    ///   - directory: The directory containing `.vm` bundles
    ///     (typically `~/.spooktacular/vms/`).
    ///   - log: Logger for diagnostic messages. Defaults to a
    ///     silent provider.
    /// - Returns: An array of VM names (without the `.vm` extension),
    ///   sorted alphabetically.
    public static func runningVMs(
        in directory: URL,
        log: any LogProvider = SilentLogProvider()
    ) -> [String] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            log.debug("No VM directory found at \(directory.path)")
            return []
        }

        let names = contents
            .filter { $0.pathExtension == "vm" }
            .filter { PIDFile.isRunning(bundleURL: $0) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()

        log.debug("Running VM count: \(names.count) (limit \(maxConcurrentVMs))")
        return names
    }

    /// Counts the number of VMs with an active (running) process
    /// in the given directory.
    ///
    /// - Parameters:
    ///   - directory: The directory containing `.vm` bundles.
    ///   - log: Logger for diagnostic messages. Defaults to a
    ///     silent provider.
    /// - Returns: The number of bundles with a live process.
    public static func runningCount(
        in directory: URL,
        log: any LogProvider = SilentLogProvider()
    ) -> Int {
        runningVMs(in: directory, log: log).count
    }

    /// Throws if the concurrent VM limit has been reached.
    ///
    /// Call this before starting a new VM to ensure the host
    /// can accommodate it.
    ///
    /// - Parameters:
    ///   - directory: The directory containing `.vm` bundles.
    ///   - log: Logger for diagnostic messages. Defaults to a
    ///     silent provider.
    /// - Throws: ``CapacityError/limitReached(running:)`` if
    ///   ``maxConcurrentVMs`` or more VMs are already running.
    public static func ensureCapacity(
        in directory: URL,
        log: any LogProvider = SilentLogProvider()
    ) throws {
        log.info("Checking VM capacity in \(directory.lastPathComponent)")
        let running = runningVMs(in: directory, log: log)
        guard running.count < maxConcurrentVMs else {
            log.error("Capacity check failed: \(running.count) VMs running (limit \(maxConcurrentVMs))")
            throw CapacityError.limitReached(running: running)
        }
        log.debug("Capacity OK: \(running.count)/\(maxConcurrentVMs) slots used")
    }
}

/// An error indicating the concurrent VM limit has been reached.
public enum CapacityError: Error, Sendable, LocalizedError, Equatable {

    /// The host is already running the maximum number of VMs.
    ///
    /// - Parameter running: The names of the currently running VMs.
    case limitReached(running: [String])

    public var errorDescription: String? {
        switch self {
        case .limitReached(let running):
            let names = running.joined(separator: ", ")
            return "Cannot start VM: Apple Silicon limit of \(CapacityCheck.maxConcurrentVMs) concurrent VMs reached. "
                + "Currently running: \(names)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .limitReached(let running):
            if let first = running.first {
                return "Stop a running VM first with 'spook stop \(first)', then retry."
            }
            return "Stop a running VM first with 'spook stop <name>', then retry."
        }
    }
}

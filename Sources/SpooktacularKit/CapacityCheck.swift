import Foundation
import os

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

    /// Counts the number of VMs with an active (running) process
    /// in the given directory.
    ///
    /// Scans all `.vm` bundle directories for PID files and checks
    /// whether the recorded process is alive.
    ///
    /// - Parameter directory: The directory containing `.vm` bundles
    ///   (typically `~/.spooktacular/vms/`).
    /// - Returns: The number of bundles with a live process.
    public static func runningCount(in directory: URL) -> Int {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            Log.capacity.debug("No VM directory found at \(directory.path, privacy: .public)")
            return 0
        }

        let count = contents
            .filter { $0.pathExtension == "vm" }
            .filter { PIDFile.isRunning(bundleURL: $0) }
            .count

        Log.capacity.debug("Running VM count: \(count) (limit \(maxConcurrentVMs))")
        return count
    }

    /// Returns the names of all currently running VMs in the
    /// given directory.
    ///
    /// - Parameter directory: The directory containing `.vm` bundles.
    /// - Returns: An array of VM names (without the `.vm` extension).
    public static func runningVMs(in directory: URL) -> [String] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "vm" }
            .filter { PIDFile.isRunning(bundleURL: $0) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Throws if the concurrent VM limit has been reached.
    ///
    /// Call this before starting a new VM to ensure the host
    /// can accommodate it.
    ///
    /// - Parameter directory: The directory containing `.vm` bundles.
    /// - Throws: ``CapacityError/limitReached(running:)`` if
    ///   ``maxConcurrentVMs`` or more VMs are already running.
    public static func ensureCapacity(in directory: URL) throws {
        Log.capacity.info("Checking VM capacity in \(directory.lastPathComponent, privacy: .public)")
        let count = runningCount(in: directory)
        if count >= maxConcurrentVMs {
            let names = runningVMs(in: directory)
            Log.capacity.error("Capacity check failed: \(count) VMs running (limit \(maxConcurrentVMs))")
            throw CapacityError.limitReached(running: names)
        }
        Log.capacity.debug("Capacity OK: \(count)/\(maxConcurrentVMs) slots used")
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

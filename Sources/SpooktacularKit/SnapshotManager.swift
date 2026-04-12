import Foundation
import os

/// Manages disk-level snapshots for virtual machine bundles.
///
/// `SnapshotManager` provides save, restore, list, and delete
/// operations for VM snapshots. Each snapshot is a full copy of
/// the VM's disk image (`disk.img`) and auxiliary storage
/// (`auxiliary.bin`), stored in a named subdirectory under the
/// bundle's `SavedStates/` directory.
///
/// ## How Snapshots Work
///
/// Unlike VZ state save (which captures in-memory VM state and
/// requires the VM to be running in the same process),
/// disk-level snapshots copy the on-disk artifacts. This means:
///
/// - The VM **must be stopped** before saving or restoring.
/// - Snapshots work across processes and reboots.
/// - Restoring replaces the current disk and auxiliary storage
///   with the snapshot copies.
///
/// ## Snapshot Directory Layout
///
/// ```
/// my-vm.vm/
/// ├── disk.img
/// ├── auxiliary.bin
/// ├── ...
/// └── SavedStates/
///     ├── clean-install/
///     │   ├── disk.img
///     │   ├── auxiliary.bin
///     │   └── snapshot-info.json
///     └── before-xcode/
///         ├── disk.img
///         ├── auxiliary.bin
///         └── snapshot-info.json
/// ```
///
/// ## Example
///
/// ```swift
/// let bundle = try VMBundle.load(from: bundleURL)
///
/// // Save a snapshot
/// try SnapshotManager.save(bundle: bundle, label: "clean-install")
///
/// // List snapshots
/// let snapshots = try SnapshotManager.list(bundle: bundle)
/// for snap in snapshots {
///     print("\(snap.label): \(snap.sizeInBytes) bytes")
/// }
///
/// // Restore a snapshot
/// try SnapshotManager.restore(bundle: bundle, label: "clean-install")
///
/// // Delete a snapshot
/// try SnapshotManager.delete(bundle: bundle, label: "clean-install")
/// ```
public enum SnapshotManager {

    /// The directory name inside a VM bundle where snapshots are stored.
    public static let savedStatesDirectory = "SavedStates"

    /// The file name for snapshot metadata inside each snapshot directory.
    public static let infoFileName = "snapshot-info.json"

    /// Files that are copied from the bundle into each snapshot.
    private static let snapshotFiles = ["disk.img", "auxiliary.bin"]

    // MARK: - Save

    /// Saves a disk-level snapshot of the VM bundle.
    ///
    /// Copies `disk.img` and `auxiliary.bin` from the bundle into
    /// a new `SavedStates/<label>/` directory, along with a
    /// `snapshot-info.json` metadata file.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle to snapshot. The VM must be stopped.
    ///   - label: A unique name for the snapshot. Must not already
    ///     exist in the bundle's `SavedStates/` directory.
    /// - Throws: ``SnapshotError/alreadyExists(label:)`` if a
    ///   snapshot with this label already exists.
    ///   ``SnapshotError/fileNotFound(path:)`` if `disk.img` is
    ///   missing from the bundle.
    public static func save(bundle: VMBundle, label: String) throws {
        let fm = FileManager.default

        let savedStatesURL = bundle.url.appendingPathComponent(savedStatesDirectory)
        let snapshotURL = savedStatesURL.appendingPathComponent(label)

        guard !fm.fileExists(atPath: snapshotURL.path) else {
            Log.vm.error("Snapshot '\(label, privacy: .public)' already exists for \(bundle.url.lastPathComponent, privacy: .public)")
            throw SnapshotError.alreadyExists(label: label)
        }

        // Verify disk.img exists before creating anything.
        let diskURL = bundle.url.appendingPathComponent("disk.img")
        guard fm.fileExists(atPath: diskURL.path) else {
            throw SnapshotError.fileNotFound(path: diskURL.path)
        }

        try fm.createDirectory(at: snapshotURL, withIntermediateDirectories: true)

        do {
            var totalSize: UInt64 = 0

            for fileName in snapshotFiles {
                let sourceFile = bundle.url.appendingPathComponent(fileName)
                let destFile = snapshotURL.appendingPathComponent(fileName)

                guard fm.fileExists(atPath: sourceFile.path) else {
                    continue
                }

                try fm.copyItem(at: sourceFile, to: destFile)

                let attrs = try fm.attributesOfItem(atPath: destFile.path)
                totalSize += (attrs[.size] as? UInt64) ?? 0
            }

            // Write snapshot-info.json.
            let info = SnapshotInfo(
                label: label,
                createdAt: Date(),
                sizeInBytes: totalSize
            )
            let data = try VMBundle.encoder.encode(info)
            try data.write(to: snapshotURL.appendingPathComponent(infoFileName))

            Log.vm.info("Saved snapshot '\(label, privacy: .public)' for \(bundle.url.lastPathComponent, privacy: .public) (\(totalSize) bytes)")
        } catch {
            // Clean up partial snapshot on failure.
            Log.vm.error("Snapshot save failed, cleaning up: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: snapshotURL)
            throw error
        }
    }

    // MARK: - Restore

    /// Restores a VM bundle from a previously saved snapshot.
    ///
    /// Replaces the bundle's `disk.img` and `auxiliary.bin` with
    /// the copies stored in the snapshot directory.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle to restore. The VM must be stopped.
    ///   - label: The label of the snapshot to restore.
    /// - Throws: ``SnapshotError/notFound(label:)`` if no snapshot
    ///   with the given label exists.
    public static func restore(bundle: VMBundle, label: String) throws {
        let fm = FileManager.default

        let savedStatesURL = bundle.url.appendingPathComponent(savedStatesDirectory)
        let snapshotURL = savedStatesURL.appendingPathComponent(label)

        guard fm.fileExists(atPath: snapshotURL.path) else {
            throw SnapshotError.notFound(label: label)
        }

        for fileName in snapshotFiles {
            let snapshotFile = snapshotURL.appendingPathComponent(fileName)
            let bundleFile = bundle.url.appendingPathComponent(fileName)

            guard fm.fileExists(atPath: snapshotFile.path) else {
                continue
            }

            // Remove the current file, then copy from snapshot.
            if fm.fileExists(atPath: bundleFile.path) {
                try fm.removeItem(at: bundleFile)
            }

            try fm.copyItem(at: snapshotFile, to: bundleFile)
        }

        Log.vm.info("Restored snapshot '\(label, privacy: .public)' for \(bundle.url.lastPathComponent, privacy: .public)")
    }

    // MARK: - List

    /// Lists all snapshots for a VM bundle.
    ///
    /// Reads the `snapshot-info.json` from each subdirectory in
    /// the bundle's `SavedStates/` directory.
    ///
    /// - Parameter bundle: The VM bundle to list snapshots for.
    /// - Returns: An array of ``SnapshotInfo`` sorted by label.
    public static func list(bundle: VMBundle) throws -> [SnapshotInfo] {
        let fm = FileManager.default
        let savedStatesURL = bundle.url.appendingPathComponent(savedStatesDirectory)

        guard fm.fileExists(atPath: savedStatesURL.path) else {
            return []
        }

        let contents = try fm.contentsOfDirectory(
            at: savedStatesURL,
            includingPropertiesForKeys: nil
        )

        var snapshots: [SnapshotInfo] = []

        for dir in contents {
            let infoURL = dir.appendingPathComponent(infoFileName)
            guard fm.fileExists(atPath: infoURL.path) else {
                continue
            }

            let data = try Data(contentsOf: infoURL)
            let info = try VMBundle.decoder.decode(SnapshotInfo.self, from: data)
            snapshots.append(info)
        }

        return snapshots.sorted { $0.label < $1.label }
    }

    // MARK: - Delete

    /// Deletes a snapshot from a VM bundle.
    ///
    /// Removes the entire snapshot directory including all copied
    /// files and the `snapshot-info.json`.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle containing the snapshot.
    ///   - label: The label of the snapshot to delete.
    /// - Throws: ``SnapshotError/notFound(label:)`` if no snapshot
    ///   with the given label exists.
    public static func delete(bundle: VMBundle, label: String) throws {
        let fm = FileManager.default

        let savedStatesURL = bundle.url.appendingPathComponent(savedStatesDirectory)
        let snapshotURL = savedStatesURL.appendingPathComponent(label)

        guard fm.fileExists(atPath: snapshotURL.path) else {
            throw SnapshotError.notFound(label: label)
        }

        try fm.removeItem(at: snapshotURL)
        Log.vm.info("Deleted snapshot '\(label, privacy: .public)' from \(bundle.url.lastPathComponent, privacy: .public)")
    }
}

// MARK: - SnapshotInfo

/// Metadata about a saved VM snapshot.
///
/// Written to `snapshot-info.json` inside each snapshot directory.
/// Contains the label, creation date, and total size of the
/// snapshot's disk artifacts.
public struct SnapshotInfo: Sendable, Codable, Equatable {

    /// The user-provided label for this snapshot.
    public let label: String

    /// When the snapshot was created.
    public let createdAt: Date

    /// Total size of the snapshot files in bytes.
    public let sizeInBytes: UInt64

    /// Creates a new snapshot info record.
    ///
    /// - Parameters:
    ///   - label: The snapshot label.
    ///   - createdAt: The creation date.
    ///   - sizeInBytes: Total size of copied files.
    public init(label: String, createdAt: Date, sizeInBytes: UInt64) {
        self.label = label
        self.createdAt = createdAt
        self.sizeInBytes = sizeInBytes
    }
}

// MARK: - SnapshotError

/// An error that occurs during snapshot operations.
public enum SnapshotError: Error, Sendable, Equatable, LocalizedError {

    /// A snapshot with this label already exists.
    case alreadyExists(label: String)

    /// No snapshot with this label was found.
    case notFound(label: String)

    /// A required file is missing from the VM bundle.
    case fileNotFound(path: String)

    /// The VM is currently running and cannot be snapshotted.
    case vmIsRunning

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let label):
            "Snapshot '\(label)' already exists."
        case .notFound(let label):
            "Snapshot '\(label)' not found."
        case .fileNotFound(let path):
            "Required file not found: \(path)"
        case .vmIsRunning:
            "Cannot snapshot a running VM. Stop the VM first."
        }
    }
}

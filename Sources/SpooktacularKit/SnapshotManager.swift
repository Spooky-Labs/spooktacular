import Foundation
import os

/// Manages disk-level snapshots for virtual machine bundles.
///
/// `SnapshotManager` provides save, restore, list, and delete
/// operations for VM snapshots. Each snapshot is a full copy of
/// the VM's disk image (`disk.img`), auxiliary storage
/// (`auxiliary.bin`), and machine identifier (`machine-identifier.bin`),
/// stored in a named subdirectory under the bundle's `SavedStates/`
/// directory.
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
/// ## APFS Copy-on-Write
///
/// On APFS volumes, both save and restore use `FileManager.copyItem`,
/// which the system maps to `clonefile(2)`. This produces a
/// copy-on-write clone instead of a byte-for-byte copy, making
/// snapshot creation and restoration near-instantaneous regardless
/// of disk image size. Only blocks that diverge after the clone
/// consume additional storage.
///
/// ## Snapshot Directory Layout
///
/// ```
/// my-vm.vm/
/// ├── disk.img
/// ├── auxiliary.bin
/// ├── machine-identifier.bin
/// ├── ...
/// └── SavedStates/
///     ├── clean-install/
///     │   ├── disk.img
///     │   ├── auxiliary.bin
///     │   ├── machine-identifier.bin
///     │   └── snapshot-info.json
///     └── before-xcode/
///         ├── disk.img
///         ├── auxiliary.bin
///         ├── machine-identifier.bin
///         └── snapshot-info.json
/// ```
///
/// ## Example
///
/// ```swift
/// let bundle = try VirtualMachineBundle.load(from: bundleURL)
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
    private static let snapshotFiles = [
        VirtualMachineBundle.diskImageFileName,
        VirtualMachineBundle.auxiliaryStorageFileName,
        VirtualMachineBundle.machineIdentifierFileName,
    ]

    // MARK: - Save

    /// Saves a disk-level snapshot of the VM bundle.
    ///
    /// Copies `disk.img`, `auxiliary.bin`, and `machine-identifier.bin`
    /// from the bundle into a new `SavedStates/<label>/` directory,
    /// along with a `snapshot-info.json` metadata file.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle to snapshot. The VM must be stopped.
    ///   - label: A unique name for the snapshot. Must not already
    ///     exist in the bundle's `SavedStates/` directory.
    /// - Throws: ``SnapshotError/alreadyExists(label:)`` if a
    ///   snapshot with this label already exists.
    ///   ``SnapshotError/fileNotFound(path:)`` if `disk.img` is
    ///   missing from the bundle.
    public static func save(bundle: VirtualMachineBundle, label: String) throws {
        Log.snapshot.info("Saving snapshot '\(label, privacy: .public)' for \(bundle.url.lastPathComponent, privacy: .public)")
        let fileManager = FileManager.default

        let savedStatesURL = bundle.url.appendingPathComponent(savedStatesDirectory)
        let snapshotURL = savedStatesURL.appendingPathComponent(label)

        guard !fileManager.fileExists(atPath: snapshotURL.path) else {
            Log.snapshot.error("Snapshot '\(label, privacy: .public)' already exists for \(bundle.url.lastPathComponent, privacy: .public)")
            throw SnapshotError.alreadyExists(label: label)
        }

        let diskURL = bundle.url.appendingPathComponent(VirtualMachineBundle.diskImageFileName)
        guard fileManager.fileExists(atPath: diskURL.path) else {
            Log.snapshot.error("Snapshot failed: disk.img not found at \(diskURL.path, privacy: .public)")
            throw SnapshotError.fileNotFound(path: diskURL.path)
        }

        try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)

        do {
            let totalSize = try copySnapshotFiles(
                from: bundle.url, to: snapshotURL
            )
            let info = SnapshotInfo(
                label: label, createdAt: Date(), sizeInBytes: totalSize
            )
            let data = try VirtualMachineBundle.encoder.encode(info)
            try data.write(to: snapshotURL.appendingPathComponent(infoFileName))

            Log.snapshot.notice("Saved snapshot '\(label, privacy: .public)' for \(bundle.url.lastPathComponent, privacy: .public) (\(totalSize) bytes)")
        } catch {
            Log.snapshot.error("Snapshot save failed, cleaning up: \(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: snapshotURL)
            throw error
        }
    }

    /// Copies snapshot files from a bundle to the snapshot directory.
    ///
    /// - Returns: The total size of all copied files in bytes.
    private static func copySnapshotFiles(
        from bundleURL: URL,
        to snapshotURL: URL
    ) throws -> UInt64 {
        let fileManager = FileManager.default
        var totalSize: UInt64 = 0

        for fileName in snapshotFiles {
            let source = bundleURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let destination = snapshotURL.appendingPathComponent(fileName)
            try fileManager.copyItem(at: source, to: destination)

            let attrs = try fileManager.attributesOfItem(atPath: destination.path)
            totalSize += (attrs[.size] as? UInt64) ?? 0
        }

        return totalSize
    }

    // MARK: - Restore

    /// Restores a VM bundle from a previously saved snapshot.
    ///
    /// Each file is restored atomically: the snapshot copy is first
    /// cloned to a `.restoring` temporary file, then swapped into
    /// place with `FileManager.replaceItemAt(_:withItemAt:)`. If the
    /// destination does not yet exist, the temporary file is moved
    /// instead (atomic on APFS). This prevents data loss if the
    /// process is interrupted mid-restore.
    ///
    /// On APFS, both `copyItem` and `replaceItemAt` leverage
    /// `clonefile(2)` for copy-on-write semantics, keeping restore
    /// near-instantaneous regardless of image size.
    ///
    /// - Parameters:
    ///   - bundle: The VM bundle to restore. The VM must be stopped.
    ///   - label: The label of the snapshot to restore.
    /// - Throws: ``SnapshotError/notFound(label:)`` if no snapshot
    ///   with the given label exists.
    public static func restore(bundle: VirtualMachineBundle, label: String) throws {
        Log.snapshot.info("Restoring snapshot '\(label, privacy: .public)' for \(bundle.url.lastPathComponent, privacy: .public)")
        let fileManager = FileManager.default

        let savedStatesURL = bundle.url.appendingPathComponent(savedStatesDirectory)
        let snapshotURL = savedStatesURL.appendingPathComponent(label)

        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            Log.snapshot.error("Snapshot '\(label, privacy: .public)' not found for \(bundle.url.lastPathComponent, privacy: .public)")
            throw SnapshotError.notFound(label: label)
        }

        for fileName in snapshotFiles {
            let snapshotFile = snapshotURL.appendingPathComponent(fileName)
            let bundleFile = bundle.url.appendingPathComponent(fileName)

            guard fileManager.fileExists(atPath: snapshotFile.path) else {
                continue
            }

            try restoreFileAtomically(
                from: snapshotFile, to: bundleFile, fileManager: fileManager
            )
        }

        Log.snapshot.notice("Restored snapshot '\(label, privacy: .public)' for \(bundle.url.lastPathComponent, privacy: .public)")
    }

    /// Restores a single file atomically from a snapshot source.
    ///
    /// 1. Copies `source` to a `.restoring` temp alongside `destination`.
    /// 2. If `destination` exists, uses `replaceItemAt` for an atomic swap.
    /// 3. If `destination` does not exist, moves the temp file into place
    ///    (`moveItem` is atomic on APFS).
    ///
    /// The temp file is cleaned up on failure so it does not accumulate.
    private static func restoreFileAtomically(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".restoring")

        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }

        try fileManager.copyItem(at: source, to: tempURL)

        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - List

    /// Lists all snapshots for a VM bundle.
    ///
    /// Reads the `snapshot-info.json` from each subdirectory in
    /// the bundle's `SavedStates/` directory.
    ///
    /// - Parameter bundle: The VM bundle to list snapshots for.
    /// - Returns: An array of ``SnapshotInfo`` sorted by label.
    public static func list(bundle: VirtualMachineBundle) throws -> [SnapshotInfo] {
        Log.snapshot.debug("Listing snapshots for \(bundle.url.lastPathComponent, privacy: .public)")
        let fileManager = FileManager.default
        let savedStatesURL = bundle.url.appendingPathComponent(savedStatesDirectory)

        guard fileManager.fileExists(atPath: savedStatesURL.path) else {
            Log.snapshot.debug("No SavedStates directory for \(bundle.url.lastPathComponent, privacy: .public)")
            return []
        }

        let snapshots = try fileManager.contentsOfDirectory(
            at: savedStatesURL,
            includingPropertiesForKeys: nil
        )
        .compactMap { dir -> SnapshotInfo? in
            let infoURL = dir.appendingPathComponent(infoFileName)
            guard fileManager.fileExists(atPath: infoURL.path) else { return nil }
            let data = try Data(contentsOf: infoURL)
            return try VirtualMachineBundle.decoder.decode(SnapshotInfo.self, from: data)
        }
        .sorted { $0.label < $1.label }

        Log.snapshot.debug("Found \(snapshots.count) snapshot(s) for \(bundle.url.lastPathComponent, privacy: .public)")
        return snapshots
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
    public static func delete(bundle: VirtualMachineBundle, label: String) throws {
        Log.snapshot.info("Deleting snapshot '\(label, privacy: .public)' from \(bundle.url.lastPathComponent, privacy: .public)")
        let fileManager = FileManager.default

        let savedStatesURL = bundle.url.appendingPathComponent(savedStatesDirectory)
        let snapshotURL = savedStatesURL.appendingPathComponent(label)

        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            Log.snapshot.error("Snapshot '\(label, privacy: .public)' not found for deletion in \(bundle.url.lastPathComponent, privacy: .public)")
            throw SnapshotError.notFound(label: label)
        }

        try fileManager.removeItem(at: snapshotURL)
        Log.snapshot.info("Deleted snapshot '\(label, privacy: .public)' from \(bundle.url.lastPathComponent, privacy: .public)")
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

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let label):
            "Snapshot '\(label)' already exists."
        case .notFound(let label):
            "Snapshot '\(label)' not found."
        case .fileNotFound(let path):
            "Required file not found: \(path)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .alreadyExists(let label):
            "Choose a different label, or delete the existing snapshot with 'spook snapshot delete <vm> \(label)'."
        case .notFound:
            "Run 'spook snapshots <vm>' to see available snapshots."
        case .fileNotFound:
            "The VM bundle may be corrupted. Recreate it with 'spook delete <name>' and 'spook create <name>'."
        }
    }
}

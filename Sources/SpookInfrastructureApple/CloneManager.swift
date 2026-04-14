import Foundation
import SpookCore
import SpookApplication
import os
@preconcurrency import Virtualization

/// Creates copy-on-write clones of virtual machine bundles.
///
/// `CloneManager` uses APFS `clonefile(2)` for the disk image,
/// which creates an instant copy that shares physical blocks
/// with the source. A 30 GB disk image clones in milliseconds.
///
/// Every clone receives a **new** `VZMacMachineIdentifier` to
/// ensure each VM has a unique identity. Reusing identifiers
/// across VMs causes undefined behavior in the Virtualization
/// framework.
///
/// ## Example
///
/// ```swift
/// let source = try VirtualMachineBundle.load(from: sourceURL)
/// let clone = try CloneManager.clone(source: source, to: destinationURL)
///
/// // clone.spec == source.spec (preserved)
/// // clone.metadata.id != source.metadata.id (new identity)
/// // disk.img is a COW clone (instant, space-efficient)
/// // machine-identifier.bin is freshly generated
/// ```
///
/// ## Important
///
/// The hardware model (`hardware-model.bin`) is copied as-is
/// because it must match the macOS version installed on the
/// disk. The machine identifier (`machine-identifier.bin`) is
/// always regenerated — never copied.
public enum CloneManager {

    /// Files that are copied verbatim from source to clone.
    private static let filesToCopy = [
        VirtualMachineBundle.diskImageFileName,
        VirtualMachineBundle.auxiliaryStorageFileName,
        VirtualMachineBundle.hardwareModelFileName,
    ]

    /// Clones a VM bundle to a new location.
    ///
    /// - Parameters:
    ///   - source: The source bundle to clone.
    ///   - destination: The file URL for the new `.vm` directory.
    ///     Must not already exist.
    /// - Returns: The newly created clone bundle.
    /// - Throws: ``VirtualMachineBundleError/alreadyExists(url:)`` if the
    ///   destination already exists. File system errors if the
    ///   source files cannot be read.
    public static func clone(
        source: VirtualMachineBundle,
        to destination: URL
    ) throws -> VirtualMachineBundle {
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: destination.path) else {
            Log.clone.error("Clone destination already exists: \(destination.lastPathComponent, privacy: .public)")
            throw VirtualMachineBundleError.alreadyExists(url: destination)
        }

        Log.clone.info("Cloning '\(source.url.lastPathComponent, privacy: .public)' → '\(destination.lastPathComponent, privacy: .public)'")

        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        do {
            // Check if the source volume supports APFS cloning.
            // FileManager.copyItem uses clonefile(2) automatically on
            // APFS, but we log a warning when the volume doesn't
            // support it so callers know they're getting a full copy.
            let values = try source.url.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
            if values.volumeSupportsFileCloning != true {
                Log.clone.warning("Volume does not support APFS cloning — falling back to full copy")
            }

            for fileName in filesToCopy {
                let sourceFile = source.url.appendingPathComponent(fileName)
                let destinationFile = destination.appendingPathComponent(fileName)

                guard fileManager.fileExists(atPath: sourceFile.path) else {
                    Log.clone.debug("Skipping \(fileName, privacy: .public) — not present in source")
                    continue
                }

                Log.clone.debug("Copying \(fileName, privacy: .public)")
                try fileManager.copyItem(at: sourceFile, to: destinationFile)
            }

            Log.clone.debug("Generating new VZMacMachineIdentifier for clone")
            let newIdentifier = VZMacMachineIdentifier()
            try newIdentifier.dataRepresentation.write(
                to: destination.appendingPathComponent(VirtualMachineBundle.machineIdentifierFileName)
            )

            let spec = source.spec
            try VirtualMachineBundle.writeSpec(spec, to: destination)

            var metadata = VirtualMachineMetadata()
            metadata.setupCompleted = source.metadata.setupCompleted
            try VirtualMachineBundle.writeMetadata(metadata, to: destination)

            Log.clone.notice("Clone complete: '\(destination.lastPathComponent, privacy: .public)'")
            return VirtualMachineBundle(
                url: destination,
                spec: spec,
                metadata: metadata
            )
        } catch {
            Log.clone.error("Clone failed, cleaning up: \(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}

import Foundation
import SpookCore
import SpookApplication
import CryptoKit
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
            let destIdentifierURL = destination.appendingPathComponent(
                VirtualMachineBundle.machineIdentifierFileName
            )
            try newIdentifier.dataRepresentation.write(to: destIdentifierURL)

            // Verify the new identifier landed on disk with non-zero
            // bytes AND is not a byte-for-byte twin of the source's
            // identifier. Without this check, a silent write failure
            // (permission issue, full disk, FS race) could leave the
            // clone pointing at the source's identifier — reuse of
            // `VZMacMachineIdentifier` across VMs is undefined
            // behavior per Apple's docs and presents cross-VM
            // identity collisions at boot.
            try Self.verifyMachineIdentifier(
                at: destIdentifierURL,
                differsFromSourceAt: source.url.appendingPathComponent(
                    VirtualMachineBundle.machineIdentifierFileName
                )
            )

            let spec = source.spec
            try VirtualMachineBundle.writeSpec(spec, to: destination)

            var metadata = VirtualMachineMetadata()
            metadata.setupCompleted = source.metadata.setupCompleted
            try VirtualMachineBundle.writeMetadata(metadata, to: destination)

            // Inherit the source bundle's data-at-rest protection
            // class — a CUFUA-protected source should never
            // produce a `.none` clone on disk. We re-apply
            // explicitly rather than relying on FileManager.copyItem
            // to carry the class across, because APFS clonefile(2)
            // preserves the class but FallbackCopy may not.
            if let srcClass = try? BundleProtection.current(at: source.url) {
                try? BundleProtection.apply(srcClass, to: destination)
                try? BundleProtection.propagate(to: destination)
            }

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

    /// Reads the freshly-written clone identifier back from disk and
    /// asserts it is non-empty and distinct from the source VM's
    /// identifier. Uses SHA-256 over the raw bytes so the comparison
    /// surfaces on any single-byte difference.
    ///
    /// See Apple docs:
    /// - [`VZMacMachineIdentifier`](https://developer.apple.com/documentation/virtualization/vzmacmachineidentifier)
    /// - [`SHA256`](https://developer.apple.com/documentation/cryptokit/sha256)
    ///
    /// - Parameters:
    ///   - cloneURL: URL to the clone's `machine-identifier.bin`.
    ///   - sourceURL: URL to the source's `machine-identifier.bin`.
    /// - Throws: ``CloneManagerError/identifierNotWritten`` when the
    ///   clone file is missing or empty;
    ///   ``CloneManagerError/identifierMatchesSource`` when the clone
    ///   SHA-256 equals the source's.
    static func verifyMachineIdentifier(
        at cloneURL: URL,
        differsFromSourceAt sourceURL: URL
    ) throws {
        let cloneData = try Data(contentsOf: cloneURL)
        guard !cloneData.isEmpty else {
            throw CloneManagerError.identifierNotWritten(path: cloneURL.path)
        }
        // If the source doesn't have an identifier file (fresh IPSW
        // install case, or test fixture without an identifier on
        // source), we only assert the clone bytes are present.
        guard let sourceData = try? Data(contentsOf: sourceURL),
              !sourceData.isEmpty else {
            return
        }
        let cloneHash = SHA256.hash(data: cloneData)
        let sourceHash = SHA256.hash(data: sourceData)
        guard cloneHash != sourceHash else {
            throw CloneManagerError.identifierMatchesSource
        }
    }
}

// MARK: - Errors

/// Errors raised by ``CloneManager`` during clone-side verification.
///
/// These are returned after the APFS clonefile / identifier write path
/// to fail the clone loudly when the write didn't actually produce a
/// distinct VM identity.
public enum CloneManagerError: Error, Sendable, Equatable, LocalizedError {

    /// The freshly-written `machine-identifier.bin` is missing or empty.
    ///
    /// - Parameter path: Absolute path that was expected to contain
    ///   the new identifier bytes.
    case identifierNotWritten(path: String)

    /// The new identifier's SHA-256 equals the source's, which would
    /// produce two VMs with the same `VZMacMachineIdentifier` — an
    /// Apple-documented undefined-behavior scenario.
    case identifierMatchesSource

    public var errorDescription: String? {
        switch self {
        case .identifierNotWritten(let path):
            "Clone verification failed: machine-identifier.bin at '\(path)' is missing or empty."
        case .identifierMatchesSource:
            "Clone verification failed: the new VM identifier is byte-identical to the source. "
            + "Reusing a VZMacMachineIdentifier across VMs is undefined behavior."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .identifierNotWritten:
            "Delete the partial clone directory and retry. Verify the host has free disk space "
            + "and that the destination volume is writable."
        case .identifierMatchesSource:
            "Delete the clone and retry. If the error persists, report a bug at "
            + "https://github.com/spookylabs/spooktacular/issues — the Virtualization framework "
            + "may have regressed VZMacMachineIdentifier randomness."
        }
    }
}

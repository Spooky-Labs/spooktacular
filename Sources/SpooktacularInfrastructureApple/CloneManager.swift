import Foundation
import SpooktacularCore
import SpooktacularApplication
import CryptoKit
import os
@preconcurrency import Virtualization

/// Creates copy-on-write clones of virtual machine bundles.
///
/// `CloneManager` uses APFS `clonefile(2)` for the disk image,
/// which creates an instant copy that shares physical blocks
/// with the source. A 30 GB disk image clones in milliseconds.
///
/// A clone inherits the source's `VZMacMachineIdentifier` because
/// that identifier is paired with the auxiliary storage the installer
/// personalized: Apple requires a VM loaded from disk to restore "the
/// hardwareModel, machineIdentifier and auxiliaryStorage properties to
/// their original values". The **MAC address is regenerated**, so
/// clones remain distinct on the network.
///
/// ## Example
///
/// ```swift
/// let source = try VirtualMachineBundle.load(from: sourceURL)
/// let clone = try CloneManager.clone(source: source, to: destinationURL)
///
/// // clone.spec == source.spec (preserved)
/// // clone.metadata.id != source.metadata.id (new bundle identity)
/// // the disk is a COW clone (instant, space-efficient)
/// // machine-identifier.bin is copied, staying paired with auxiliary.bin
/// ```
///
/// ## Important
///
/// The hardware model (`hardware-model.bin`) is copied as-is because it
/// must match the macOS version installed on the disk, and the machine
/// identifier is copied for the same reason. Apple warns that running
/// two VMs concurrently with the same identifier is undefined in the
/// guest — so a clone is a replacement for its source, not a sibling to
/// run beside it.
public enum CloneManager {

    /// Bundle files a clone carries over.
    ///
    /// Both disk shapes appear here because a bundle has exactly one of
    /// them: Linux bundles own a standalone `disk.img`, while
    /// overlay-backed macOS bundles own `disk-overlay.asif` and share
    /// their base. Missing entries are skipped, so listing both is
    /// correct rather than wasteful.
    private static let filesToCopy = [
        VirtualMachineBundle.diskImageFileName,
        VirtualMachineBundle.overlayFileName,
        VirtualMachineBundle.auxiliaryStorageFileName,
        VirtualMachineBundle.hardwareModelFileName,
        VirtualMachineBundle.machineIdentifierFileName,
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
        to destination: URL,
        displayName: String
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

            // The machine identifier is copied with the rest of the
            // platform files above, NOT regenerated.
            //
            // A clone carries the source's installed auxiliary storage,
            // which `VZMacOSInstaller` personalized against the
            // identifier present at install time. Apple requires that a
            // VM loaded from disk restore "the hardwareModel,
            // machineIdentifier and auxiliaryStorage properties to
            // their original values", so breaking that pairing leaves
            // the clone with boot state signed for an identity it no
            // longer has.
            //
            // Apple also warns that running two VMs concurrently with
            // the same identifier is undefined in the guest. Both
            // statements are true at once, and the pairing wins: a
            // clone that cannot boot is worse than one that must not
            // run beside its source. The MAC address IS regenerated
            // below, so clones stay distinct on the network.
            // Only assert the copy when the source actually had an
            // identifier: a bundle created but never installed has none
            // yet, and a clone of it legitimately has none either.
            let sourceIdentifierURL = source.url.appendingPathComponent(
                VirtualMachineBundle.machineIdentifierFileName
            )
            if FileManager.default.fileExists(atPath: sourceIdentifierURL.path) {
                try Self.verifyMachineIdentifier(
                    at: destination.appendingPathComponent(
                        VirtualMachineBundle.machineIdentifierFileName
                    )
                )
            }

            // Regenerate the MAC address on clone. Without this,
            // two simultaneously-running clones collide at the
            // link layer — they present the same MAC to the
            // host's virtio-net bridge, which fights for the
            // DHCP lease and silently drops packets for whichever
            // VM loses. Apple's sample code omits this only
            // because the sample runs a single VM at a time; any
            // real pool usage needs the fresh MAC. `MACAddress.generate()`
            // produces a locally-administered unicast address
            // (first octet `02:xx:…`) per RFC 7042 § 2.1.1, the
            // reserved range for private / site-local use.
            let spec = source.spec.with(macAddress: .set(MACAddress.generate()))
            try VirtualMachineBundle.writeSpec(spec, to: destination)

            var metadata = VirtualMachineMetadata(displayName: displayName)
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
    static func verifyMachineIdentifier(at cloneURL: URL) throws {
        guard let cloneData = try? Data(contentsOf: cloneURL), !cloneData.isEmpty else {
            throw CloneManagerError.identifierNotWritten(path: cloneURL.path)
        }
    }
}

/// Failures raised while cloning a VM bundle.
public enum CloneManagerError: Error, Sendable, Equatable, LocalizedError {

    /// The clone's `machine-identifier.bin` is missing or empty after
    /// the platform files were copied.
    case identifierNotWritten(path: String)

    public var errorDescription: String? {
        switch self {
        case .identifierNotWritten(let path):
            "The clone's machine identifier was not written to '\(path)'."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .identifierNotWritten:
            "Delete the partial clone directory and retry. Verify the host has free disk space "
            + "and that the destination volume is writable."
        }
    }
}

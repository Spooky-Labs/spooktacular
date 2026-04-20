import Foundation
import SpooktacularCore
import SpooktacularApplication
import os
@preconcurrency import Virtualization

/// Imports a portable Spooktacular VM bundle into the local
/// library directory.
///
/// The `.vm` bundle layout (see ``VirtualMachineBundle``) is
/// already self-contained — disk image, aux storage, hardware
/// model, machine identifier, optional save-state file — so
/// "import" reduces to three operations:
///
/// 1. **APFS-cloned copy** of the bundle directory from source
///    to `<vmsDirectory>/<name>.vm`. We re-use
///    `FileManager.copyItem(at:to:)` so the clone uses
///    `clonefile(2)` on APFS volumes and falls back cleanly on
///    other filesystems. Same primitive as ``CloneManager``.
/// 2. **Identity regeneration** — the imported bundle must not
///    share its `VZMacMachineIdentifier` or MAC address with
///    the host that originally authored it. We write a fresh
///    `machine-identifier.bin` via `VZMacMachineIdentifier()`
///    and mutate the spec's MAC to a new locally-administered
///    address via ``MACAddress/generate()``.
/// 3. **Protection-class propagation** — the imported bundle
///    inherits the *destination* host's bundle-protection
///    policy (CUFUA on portable Macs, `.none` on fixed
///    servers) rather than whatever the source host applied.
///    This keeps the import "feels native" — the imported VM
///    has the same at-rest behavior as a VM created locally.
///
/// The import is **cooperative with the `spooktacular` CLI and
/// SwiftUI GUI**: both call this function via the same entry
/// point so semantics never diverge.
///
/// ## Name collisions
///
/// If `<vmsDirectory>/<name>.vm` already exists, the importer
/// appends an incrementing suffix (`-2`, `-3`, …) rather than
/// overwriting. This matches Finder's "copy 2" behavior and
/// prevents an import from silently destroying an existing VM.
///
/// ## Apple APIs used
///
/// - [`FileManager.copyItem(at:to:)`](https://developer.apple.com/documentation/foundation/filemanager/copyitem(at:to:))
///   — inherits `clonefile(2)` automatically on APFS.
/// - [`VZMacMachineIdentifier`](https://developer.apple.com/documentation/virtualization/vzmacmachineidentifier)
///   — fresh hardware identity per host.
public enum BundleImporter {

    /// Errors raised by ``BundleImporter/import(sourceURL:intoDirectory:)``.
    public enum ImportError: Error, LocalizedError {
        /// The source URL is not a `.vm` directory that can be
        /// loaded as a ``VirtualMachineBundle``.
        case invalidSource(url: URL, reason: String)

        /// After 100 suffix attempts no collision-free name was
        /// available. Should be impossible in practice.
        case unresolvableNameCollision(base: String)

        public var errorDescription: String? {
            switch self {
            case .invalidSource(let url, let reason):
                return "Cannot import '\(url.lastPathComponent)': \(reason)"
            case .unresolvableNameCollision(let base):
                return "Too many bundles named '\(base)' in the library. Rename one and retry."
            }
        }
    }

    /// Logger for import operations.
    private static let log = Logger(subsystem: "com.spooktacular.bundle", category: "import")

    /// Imports `sourceURL` into `intoDirectory`, returning the
    /// freshly-loaded ``VirtualMachineBundle``.
    ///
    /// - Parameters:
    ///   - sourceURL: A `.vm` directory to import. Must be
    ///     loadable via `VirtualMachineBundle.load(from:)`.
    ///   - intoDirectory: The library VM directory (e.g.,
    ///     `SpooktacularPaths.vms`, `~/.spooktacular/vms/`).
    /// - Returns: The imported bundle, keyed by its final name
    ///   in the library (which may differ from the source
    ///   filename on name collision).
    /// - Throws: ``ImportError`` or underlying
    ///   `VirtualMachineBundleError` on failure.
    public static func `import`(
        sourceURL: URL,
        intoDirectory: URL
    ) throws -> VirtualMachineBundle {

        // Validate the source is actually a VM bundle before we
        // start copying gigabytes of data.
        let _: VirtualMachineBundle
        do {
            _ = try VirtualMachineBundle.load(from: sourceURL)
        } catch {
            throw ImportError.invalidSource(
                url: sourceURL,
                reason: "not a valid VM bundle (\(error.localizedDescription))"
            )
        }

        try FileManager.default.createDirectory(
            at: intoDirectory,
            withIntermediateDirectories: true
        )

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destinationURL = try resolveNonCollidingURL(
            baseName: baseName,
            in: intoDirectory
        )

        log.info("Importing '\(sourceURL.lastPathComponent, privacy: .public)' → '\(destinationURL.lastPathComponent, privacy: .public)'")

        // Probe the *destination* volume for APFS clone support
        // — it's the destination that determines whether
        // `clonefile(2)` fires vs. a full read-and-write.
        // Importing a 64 GB bundle into an APFS `~/Library` is
        // millisecond-fast; importing into a FAT32 USB stick
        // will be minutes-slow because the FS can't share
        // extents. Apple's docs for `volumeSupportsFileCloningKey`:
        // https://developer.apple.com/documentation/foundation/urlresourcekey/volumesupportsfilecloningkey
        if let destSupports = try? intoDirectory.resourceValues(
            forKeys: [.volumeSupportsFileCloningKey]
        ).volumeSupportsFileCloning, !destSupports {
            log.warning("Destination volume does not support APFS cloning — falling back to full copy")
        }

        // Let FileManager pick `clonefile(2)` on APFS. Same
        // primitive `CloneManager` uses — keeping both paths on
        // a single copy-engine avoids divergence when Apple
        // updates APFS semantics. On non-APFS destinations
        // `copyItem` falls through to `copyfile(3)` without the
        // clone flag, producing a full copy.
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        // Regenerate hardware identity on the clone — see class
        // docstring for why.
        try regenerateIdentity(at: destinationURL)

        // Apply the *destination* host's protection class (not
        // the source's). A bundle arriving from a laptop
        // (CUFUA) shouldn't constrain the host; a bundle
        // arriving from a fixed server shouldn't drop the
        // laptop's CUFUA policy. `applyRecommendedPolicy` uses
        // the same host-detection heuristic as first-time
        // bundle creation.
        let (protection, _) = BundleProtection.recommendedPolicy()
        try? BundleProtection.apply(protection, to: destinationURL)
        try? BundleProtection.propagate(to: destinationURL)

        // Remove any inherited save-state file. This is not a
        // defensive cleanup — it's REQUIRED by Apple's own
        // design. Per WWDC23 "Create seamless experiences with
        // Virtualization" (session 10007), save-state files are
        // hardware-encrypted per-host:
        //
        // > These files are hardware encrypted to provide the
        // > strongest possible guarantees. No other Mac or user
        // > account can read another's save file, or restore
        // > the virtual machine.
        //
        // A save-file imported from a different Mac will FAIL
        // `restoreMachineStateFrom` with the framework's
        // incompatibility error. Our `startOrResume` handles
        // that by falling back to a cold boot, but removing the
        // file up-front avoids a spurious "restore failed,
        // cold-booting" log line on the first post-import
        // start. Even when the import is intra-host, the
        // save-file's pre-import disk bytes won't match the
        // post-import disk state, so restore would fail then
        // too.
        //
        // Net: the save-file is a per-host artifact and never
        // survives a bundle move. Removing it here makes that
        // contract explicit.
        let savedStateURL = destinationURL.appendingPathComponent(
            VirtualMachineBundle.savedStateFileName
        )
        try? FileManager.default.removeItem(at: savedStateURL)

        let bundle = try VirtualMachineBundle.load(from: destinationURL)
        log.notice("Imported '\(destinationURL.lastPathComponent, privacy: .public)'")
        return bundle
    }

    /// Writes a fresh `VZMacMachineIdentifier` + new MAC
    /// address into the clone at `bundleURL`. Mirrors the
    /// regeneration ``CloneManager`` does post-copy.
    private static func regenerateIdentity(at bundleURL: URL) throws {
        let newIdentifier = VZMacMachineIdentifier()
        try newIdentifier.dataRepresentation.write(
            to: bundleURL.appendingPathComponent(
                VirtualMachineBundle.machineIdentifierFileName
            )
        )

        // Rewrite the spec with a fresh MAC. `BundleImporter`
        // is the correct home for this (not a
        // `VirtualMachineBundle` method) because identity
        // regeneration is an import/clone concern, not a
        // property of the bundle itself.
        let existing = try VirtualMachineBundle.load(from: bundleURL)
        let rekeyed = existing.spec.with(macAddress: .set(MACAddress.generate()))
        try VirtualMachineBundle.writeSpec(rekeyed, to: bundleURL)
    }

    /// Finds the first free `<baseName>.vm`, `<baseName>-2.vm`,
    /// `<baseName>-3.vm`, … up to `<baseName>-99.vm` in `dir`.
    /// Throws ``ImportError/unresolvableNameCollision`` if all
    /// 100 slots are taken.
    private static func resolveNonCollidingURL(
        baseName: String,
        in dir: URL
    ) throws -> URL {
        let fm = FileManager.default
        let direct = dir.appendingPathComponent("\(baseName).vm")
        if !fm.fileExists(atPath: direct.path) {
            return direct
        }
        for i in 2..<100 {
            let candidate = dir.appendingPathComponent("\(baseName)-\(i).vm")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw ImportError.unresolvableNameCollision(base: baseName)
    }
}

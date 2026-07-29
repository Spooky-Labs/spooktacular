import Foundation
import DiskImageKit
import Virtualization
import os

/// Creates and opens the Apple Sparse Image Format (ASIF) disk images
/// that back macOS VMs.
///
/// Spooktacular installs macOS **once** into a base image and then
/// gives every VM its own overlay layered on top of it — the workflow
/// Apple documents for DiskImageKit: "a shared, read-only base image
/// with per-VM overlay layers. Each virtual machine gets its own
/// overlay that captures writes while the base remains untouched."
///
/// Two invariants make that safe, and both are enforced here:
///
/// - The base is opened **read-only**. DiskImageKit only ever writes
///   to the topmost layer of a stack, so the base's `layerUUID` never
///   changes once VMs exist — which is also what makes a warm-pool
///   scrub provable rather than merely asserted.
/// - A stack is assembled only when the base's `layerUUID` still
///   matches what the VM recorded at create time. The framework
///   validates lineage itself through `parentUUID`; the explicit check
///   here exists to produce an actionable error instead of a raw
///   framework failure.
@available(macOS 27, *)
public enum DiskStack {

    /// ASIF images in this project use 512-byte blocks.
    private static let blockSize: DiskImage.BlockSize = .bytes512

    /// Bytes per block, for converting sizes to block counts.
    private static let bytesPerBlock: UInt64 = 512

    private static let log = Logger(subsystem: "com.spooktacular", category: "disk-stack")

    /// Creates an empty sparse base image.
    ///
    /// - Parameters:
    ///   - url: Destination for the new `.asif` file.
    ///   - sizeInBytes: Logical size of the image. ASIF is sparse, so
    ///     the file occupies a few megabytes regardless of this value.
    /// - Returns: The new image's layer UUID, recorded by every VM
    ///   that stacks on it.
    /// - Throws: ``DiskStackError/baseLayerUUIDMissing(_:)`` when the
    ///   created image reports no UUID, or a DiskImageKit error.
    @discardableResult
    public static func createBase(at url: URL, sizeInBytes: UInt64) throws -> UUID {
        let blockCount = Int(sizeInBytes / bytesPerBlock)
        let image = try DiskImage(
            creating: .asif(url: url, blockCount: blockCount, blockSize: blockSize)
        )
        guard let layerUUID = image.layerUUID else {
            throw DiskStackError.baseLayerUUIDMissing(url)
        }
        log.notice(
            "Created ASIF base at \(url.lastPathComponent, privacy: .public) (\(blockCount) blocks)"
        )
        return layerUUID
    }

    /// Creates a VM's overlay layer on top of a base image.
    ///
    /// Layer configurations can only be used with stacking operations,
    /// so the overlay is materialized by appending it to the opened
    /// base — which is also what records its `parentUUID`.
    ///
    /// - Parameters:
    ///   - overlayURL: Destination for the new overlay file.
    ///   - baseURL: The base image to stack on.
    ///   - sizeInBytes: Optional larger size for the whole stack. When
    ///     `nil` the overlay inherits the base's size; when supplied
    ///     the stack is resized, because the topmost layer determines
    ///     a stack's effective size.
    /// - Throws: A DiskImageKit error.
    public static func createOverlay(
        at overlayURL: URL,
        base baseURL: URL,
        sizeInBytes: UInt64?
    ) throws {
        let base = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
        let layerType: DiskImage.LayerType
        if let sizeInBytes {
            layerType = .overlay(blockCount: Int(sizeInBytes / bytesPerBlock))
        } else {
            layerType = .overlay
        }
        _ = try base.appending(.asifLayer(url: overlayURL, type: layerType))
        log.notice("Created overlay at \(overlayURL.lastPathComponent, privacy: .public)")
    }

    /// Reads a base image's layer UUID.
    ///
    /// - Parameter url: The base image.
    /// - Returns: The layer UUID.
    /// - Throws: ``DiskStackError/baseLayerUUIDMissing(_:)`` when the
    ///   image reports no UUID (RAW images never have one).
    public static func baseLayerUUID(at url: URL) throws -> UUID {
        let image = try DiskImage(opening: .open(url: url, mode: .readOnly))
        guard let layerUUID = image.layerUUID else {
            throw DiskStackError.baseLayerUUIDMissing(url)
        }
        return layerUUID
    }

    /// Assembles the base + overlay stack and wraps it in a storage
    /// attachment for the Virtualization framework.
    ///
    /// - Parameters:
    ///   - baseURL: The shared read-only base image.
    ///   - overlayURL: This VM's overlay.
    ///   - expectedBaseLayerUUID: The base UUID recorded when the VM
    ///     was created. Pass `nil` to skip the check.
    /// - Returns: An attachment ready for `VZVirtioBlockDeviceConfiguration`.
    /// - Throws: ``DiskStackError/baseDrift(expected:found:)`` when the
    ///   base changed, or a DiskImageKit / Virtualization error.
    public static func attachment(
        base baseURL: URL,
        overlay overlayURL: URL,
        expectedBaseLayerUUID: UUID?
    ) throws -> VZDiskImageStorageDeviceAttachment {
        let base = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
        guard let actualUUID = base.layerUUID else {
            throw DiskStackError.baseLayerUUIDMissing(baseURL)
        }
        if let expectedBaseLayerUUID, expectedBaseLayerUUID != actualUUID {
            throw DiskStackError.baseDrift(expected: expectedBaseLayerUUID, found: actualUUID)
        }
        let overlay = try DiskImage(opening: .open(url: overlayURL))
        let stack = try base.appending(overlay)
        return try VZDiskImageStorageDeviceAttachment(diskImage: stack)
    }

    /// Opens a standalone image read-write for the installer.
    ///
    /// The base image is written exactly once, by `VZMacOSInstaller`
    /// during a base build. Every later use opens it read-only through
    /// ``attachment(base:overlay:expectedBaseLayerUUID:)``.
    ///
    /// - Parameter url: The image to open.
    /// - Returns: A read-write attachment.
    /// - Throws: A DiskImageKit / Virtualization error.
    public static func writableAttachment(at url: URL) throws -> VZDiskImageStorageDeviceAttachment {
        let image = try DiskImage(opening: .open(url: url, mode: .readWrite))
        return try VZDiskImageStorageDeviceAttachment(diskImage: image)
    }
}

/// Diagnostics for ASIF base/overlay handling.
public enum DiskStackError: Error, Sendable, Equatable, LocalizedError {

    /// A disk image reported no layer UUID.
    case baseLayerUUIDMissing(URL)

    /// The base image changed since the VM was created.
    case baseDrift(expected: UUID, found: UUID)

    public var errorDescription: String? {
        switch self {
        case .baseLayerUUIDMissing(let url):
            "Disk image at '\(url.path)' has no layer UUID."
        case .baseDrift(let expected, let found):
            "The base image changed since this VM was created (expected layer \(expected), found \(found))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .baseLayerUUIDMissing:
            "The image may be RAW rather than ASIF, or corrupt. Rebuild the base image."
        case .baseDrift:
            "Recreate this VM against the current base image."
        }
    }
}

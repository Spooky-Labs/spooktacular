import Foundation

/// Runtime metadata for a virtual machine.
///
/// `VMMetadata` tracks the identity and lifecycle state of a VM
/// bundle. It is persisted as `metadata.json` inside the bundle
/// directory and updated as the VM progresses through its
/// lifecycle.
///
/// Each VM receives a unique ``id`` at creation time.
/// The ``setupCompleted`` flag indicates whether the macOS
/// Setup Assistant has been automated and SSH is available.
///
/// ## Example
///
/// ```swift
/// var metadata = VMMetadata()
/// print(metadata.id)              // unique UUID
/// print(metadata.setupCompleted)  // false
///
/// metadata.setupCompleted = true
/// ```
public struct VMMetadata: Sendable, Codable, Equatable {

    /// A unique identifier for this virtual machine.
    ///
    /// Generated automatically at creation time. Persists across
    /// restarts and is used to distinguish VMs in the control API.
    public let id: UUID

    /// The date and time this VM was created.
    public let createdAt: Date

    /// Whether the macOS Setup Assistant has been completed.
    ///
    /// When `true`, the VM has a configured user account and
    /// SSH is enabled. Clone VMs inherit this flag from their
    /// source.
    public var setupCompleted: Bool

    /// The date and time of the last successful boot, if any.
    public var lastBootedAt: Date?

    /// Creates new metadata with a fresh unique identifier.
    public init() {
        self.id = UUID()
        self.createdAt = Date()
        self.setupCompleted = false
        self.lastBootedAt = nil
    }
}

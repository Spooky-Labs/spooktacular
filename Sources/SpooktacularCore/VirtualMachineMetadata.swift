import Foundation

/// Runtime metadata for a virtual machine.
///
/// `VirtualMachineMetadata` tracks the identity and lifecycle state of a VM
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
/// var metadata = VirtualMachineMetadata()
/// print(metadata.id)              // unique UUID
/// print(metadata.setupCompleted)  // false
///
/// metadata.setupCompleted = true
/// ```
public struct VirtualMachineMetadata: Sendable, Codable, Equatable {

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

    /// Whether this VM should be destroyed when it stops.
    ///
    /// Ephemeral VMs are used in CI pools where each job gets a
    /// clean clone that is automatically deleted after the process
    /// exits. On startup, bundles marked ephemeral with a dead PID
    /// are cleaned up.
    public var isEphemeral: Bool

    /// The date and time of the last successful boot, if any.
    public var lastBootedAt: Date?

    /// Per-workspace custom icon.
    ///
    /// Renders in the library, workspace window toolbar, and Dock
    /// tile when that workspace has focus. `nil` means fall back to
    /// ``IconSpec/defaultSpec``.
    public var iconSpec: IconSpec?

    /// Creates new metadata with a fresh unique identifier.
    public init() {
        self.id = UUID()
        self.createdAt = Date()
        self.setupCompleted = false
        self.isEphemeral = false
        self.iconSpec = nil
    }

    /// Decodes metadata with forward-compatible defaults for fields
    /// added after the bundle format shipped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.setupCompleted = try container.decode(Bool.self, forKey: .setupCompleted)
        self.isEphemeral = try container.decodeIfPresent(Bool.self, forKey: .isEphemeral) ?? false
        self.lastBootedAt = try container.decodeIfPresent(Date.self, forKey: .lastBootedAt)
        self.iconSpec = try container.decodeIfPresent(IconSpec.self, forKey: .iconSpec)
    }
}

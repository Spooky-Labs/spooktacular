import Foundation

/// Runtime metadata for a virtual machine.
///
/// `VirtualMachineMetadata` tracks the identity and lifecycle
/// state of a VM bundle. It is persisted as `metadata.json`
/// inside the bundle directory and updated as the VM
/// progresses through its lifecycle.
///
/// Each VM has two identifiers:
///
/// - ``id`` — a stable ``UUID`` assigned at creation. This is
///   the primary key used everywhere the runtime needs to
///   refer to the VM: filesystem bundle directory
///   (`~/.spooktacular/vms/<id>.vm/`), `AppState` dictionaries,
///   streaming socket filename, HTTP API routes. Persists for
///   the entire life of the VM and never changes.
///
/// - ``displayName`` — the human-readable label the user
///   picked at create time. Mutable via
///   ``Spooktacular/AppState/renameVM(id:to:)``. Non-unique;
///   two VMs can share the same display name (the CLI asks
///   the user to disambiguate by UUID when needed). Used for
///   sidebar rows, window titles, log messages, notifications.
public struct VirtualMachineMetadata: Sendable, Codable, Equatable {

    /// A unique identifier for this virtual machine.
    ///
    /// Generated automatically at creation time. Persists across
    /// restarts and is used as the primary key throughout the
    /// codebase (filesystem layout, in-memory dicts, API routes).
    /// Never changes once assigned.
    public let id: UUID

    /// The human-readable label for this VM.
    ///
    /// Mutable — `AppState.renameVM(id:to:)` rewrites this
    /// field and re-persists `metadata.json`. Non-unique across
    /// VMs; the UUID is the identity, the name is just a label.
    public var displayName: String

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

    /// Per-VM provisioning state.
    ///
    /// Tracks whether the guest has accepted the Spooktacular
    /// provisioner profile and what user-data or template
    /// scripts have flowed through the shared-folder queue. The
    /// struct is always present (new-VM default is a fresh,
    /// nothing-installed state) so UI code doesn't have to
    /// branch on nil vs non-nil — an unused field is just an
    /// empty ``ProvisioningStatus``.
    ///
    /// Persisted with the rest of `metadata.json`, so it travels
    /// through clone, snapshot, and export workflows — a golden
    /// image carries its own "what's already provisioned"
    /// record, and its clones inherit it until new scripts run
    /// on them.
    public var provisioningStatus: ProvisioningStatus

    /// A **non-secret** marker that the VM still needs native
    /// first-boot provisioning (macOS 27 `VZMacGuestProvisioningOptions`)
    /// applied, then cleared.
    ///
    /// Set at create time for VMs that provision natively but don't boot
    /// during `create` — `--remote-desktop`, `--openclaw`,
    /// `--user-data`. `spook start` (and the GUI's start) consumes it on
    /// the first successful boot and nils it, so the framework's
    /// once-only provisioning options are applied exactly when they're
    /// honoured. `nil` once provisioned, and for VMs that never need it
    /// (a runner VM boots during `create`, so its spec is applied and
    /// discarded there).
    ///
    /// The account **password is deliberately NOT stored here**. This
    /// marker holds only the non-secret fields (username, full name, the
    /// auto-login / remote-login booleans). The password lives only in
    /// the macOS login Keychain, keyed by ``id``, written at `create`,
    /// read once at the first `start`, and deleted after a successful
    /// boot — so `metadata.json` never carries a plaintext secret. See
    /// ``PendingProvisioning``.
    public var pendingProvisioning: PendingProvisioning?

    /// Creates new metadata with the supplied identifier and
    /// display name.
    ///
    /// - Parameters:
    ///   - id: The VM's stable UUID. Defaults to a fresh
    ///     `UUID()` for callers that don't care which one is
    ///     minted; ``SpooktacularInfrastructureApple/VirtualMachineBundle/create(at:spec:displayName:)``
    ///     passes the UUID extracted from the bundle directory
    ///     basename so the filesystem and metadata always agree.
    ///   - displayName: The user-facing label. Stored verbatim
    ///     — callers are responsible for any trimming /
    ///     normalisation they want.
    public init(id: UUID = UUID(), displayName: String) {
        self.id = id
        self.displayName = displayName
        self.createdAt = Date()
        self.setupCompleted = false
        self.isEphemeral = false
        self.iconSpec = nil
        self.provisioningStatus = ProvisioningStatus()
        self.pendingProvisioning = nil
    }

    /// Decodes metadata with forward-compatible defaults for
    /// fields added after the bundle format shipped.
    ///
    /// `displayName` falls back to the empty string when absent.
    /// The bundle loader treats an empty display name as the
    /// trigger for its one-shot UUID migration — see
    /// ``VirtualMachineBundle/load(from:)``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.setupCompleted = try container.decode(Bool.self, forKey: .setupCompleted)
        self.isEphemeral = try container.decodeIfPresent(Bool.self, forKey: .isEphemeral) ?? false
        self.lastBootedAt = try container.decodeIfPresent(Date.self, forKey: .lastBootedAt)
        self.iconSpec = try container.decodeIfPresent(IconSpec.self, forKey: .iconSpec)
        self.provisioningStatus =
            try container.decodeIfPresent(ProvisioningStatus.self, forKey: .provisioningStatus)
            ?? ProvisioningStatus()
        self.pendingProvisioning =
            try container.decodeIfPresent(PendingProvisioning.self, forKey: .pendingProvisioning)
    }
}

/// Per-VM provisioning state, tracked in `metadata.json`.
///
/// Lightweight summary of the "what's the state of this VM's
/// first-boot script?" question. Live queue/log state is read
/// off disk via ``SpooktacularInfrastructureApple/VirtualMachineBundle/readProvisioningActivity()``
/// — this struct persists only the durable, cross-restart bits
/// that survive snapshot/clone.
public struct ProvisioningStatus: Sendable, Codable, Equatable {

    /// Whether the guest has the Spooktacular Guest Tools
    /// provisioner LaunchDaemon installed and approved.
    /// Registered via `SMAppService.daemon(plistName:)` from
    /// inside the guest's Guest Tools menu bar.
    ///
    /// When `false`, any `first-boot.sh` the host drops into
    /// the bundle's `provision/` share sits there inert — the
    /// daemon that runs it at boot isn't loaded.
    public var profileInstalled: Bool

    /// Timestamp of the last first-boot run the provisioner
    /// daemon reported completed (exit 0 or non-zero — both
    /// count). `nil` if no script has run yet.
    public var lastRunCompletedAt: Date?

    /// Human-readable summary of the most recent failure, if
    /// any. Cleared when a subsequent run succeeds.
    public var lastErrorMessage: String?

    /// Optional user-settable label describing what this VM
    /// is *for* — `"ios-builder"`, `"tenant-a-dev"`,
    /// `"screensharing-demo"`. Consumed by the sidebar for
    /// grouping/filtering and by the Guest Tools menu bar to
    /// remind the user which workload this VM runs.
    public var workloadLabel: String?

    public init(
        profileInstalled: Bool = false,
        lastRunCompletedAt: Date? = nil,
        lastErrorMessage: String? = nil,
        workloadLabel: String? = nil
    ) {
        self.profileInstalled = profileInstalled
        self.lastRunCompletedAt = lastRunCompletedAt
        self.lastErrorMessage = lastErrorMessage
        self.workloadLabel = workloadLabel
    }
}

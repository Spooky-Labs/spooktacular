import Foundation

/// Content-addressed cache for the manifests + pkgs the
/// embedded MDM serves over its `/mdm/manifest/<id>` and
/// `/mdm/pkg/<id>` endpoints.
///
/// One ``Item`` per dispatched user-data run. The ID — a
/// UUID — is the path component the embedded MDM server
/// uses to look the bytes up at fetch time, and it's the
/// component baked into the `ManifestURL` we send the device
/// in the InstallEnterpriseApplication command.
///
/// ## Lifecycle
///
/// Items are inserted by ``MDMUserDataDispatcher`` when it
/// builds a fresh user-data pkg; they're removed by the
/// dispatcher (or operator) once the device acks the
/// command, freeing memory. Nothing else writes to the
/// store, so the actor's API is small.
///
/// ## Why in-memory
///
/// Per-run pkgs are small (script wrapper + manifest, a few
/// KB) and short-lived (delivered + ack'd within seconds for
/// most user-data scripts). A host restart loses them but
/// the device naturally retries via the queue's re-delivery
/// semantics — and the dispatcher would re-build the pkg on
/// the next attempt anyway. Persistence layers in later if
/// scale demands it; this actor's API stays stable.
public actor MDMContentStore {

    // MARK: - Types

    /// A pre-built pkg + its manifest, keyed by an opaque ID
    /// that matches the path component baked into the
    /// command's `ManifestURL`.
    public struct Item: Sendable {
        /// Bytes of the .pkg that the device downloads from
        /// `/mdm/pkg/<id>`.
        public let pkgData: Data

        /// Bytes of the manifest plist served at
        /// `/mdm/manifest/<id>`. Already includes
        /// `assets[0].url` pointing at the pkg endpoint.
        public let manifestData: Data

        /// Bundle identifier the manifest declares. Useful
        /// for diagnostics + audit; the device echoes it back
        /// in the ack response.
        public let bundleIdentifier: String

        /// When the dispatcher inserted this item — set by
        /// ``MDMContentStore`` at insertion time.
        public let createdAt: Date

        public init(
            pkgData: Data,
            manifestData: Data,
            bundleIdentifier: String,
            createdAt: Date
        ) {
            self.pkgData = pkgData
            self.manifestData = manifestData
            self.bundleIdentifier = bundleIdentifier
            self.createdAt = createdAt
        }
    }

    // MARK: - State

    private var items: [UUID: Item] = [:]

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Mutators

    /// Stores the pkg + manifest under a fresh UUID and
    /// returns the ID. The dispatcher uses this when it
    /// doesn't need to know the ID before building.
    public func register(
        pkgData: Data,
        manifestData: Data,
        bundleIdentifier: String
    ) -> UUID {
        let id = UUID()
        store(id: id, pkgData: pkgData, manifestData: manifestData, bundleIdentifier: bundleIdentifier)
        return id
    }

    /// Stores the pkg + manifest under a caller-supplied ID.
    /// The dispatcher uses this so it can mint the ID up
    /// front, bake it into the manifest URL paths, then
    /// register the fully-formed bytes — avoiding a
    /// chicken-and-egg between "the manifest references the
    /// pkg URL" and "the URL embeds the content-store ID".
    public func store(
        id: UUID,
        pkgData: Data,
        manifestData: Data,
        bundleIdentifier: String
    ) {
        items[id] = Item(
            pkgData: pkgData,
            manifestData: manifestData,
            bundleIdentifier: bundleIdentifier,
            createdAt: now()
        )
    }

    /// Removes the item for the given ID. Called by the
    /// dispatcher after the device acks the install command,
    /// freeing the pkg bytes from memory.
    public func remove(_ id: UUID) {
        items.removeValue(forKey: id)
    }

    // MARK: - Readers

    /// Returns the manifest bytes for the given ID, or `nil`
    /// if no item exists. The HTTP server calls this on
    /// `/mdm/manifest/<id>` GETs.
    public func manifest(forID id: UUID) -> Data? {
        items[id]?.manifestData
    }

    /// Returns the pkg bytes for the given ID, or `nil` if no
    /// item exists. The HTTP server calls this on
    /// `/mdm/pkg/<id>` GETs.
    public func pkg(forID id: UUID) -> Data? {
        items[id]?.pkgData
    }

    /// Returns the full record for the given ID, including
    /// `bundleIdentifier` + `createdAt`. Used by audit /
    /// debugging; the HTTP server only reads the byte
    /// payloads.
    public func item(forID id: UUID) -> Item? {
        items[id]
    }

    /// Total items currently in memory. Useful for metrics
    /// gauges and tests.
    public var count: Int {
        items.count
    }
}

import Foundation

/// Persists a snapshot of an ``MDMDeviceStore`` to a single
/// JSON file and loads it back. Used so the `spook mdm
/// devices` CLI can show enrolled VMs across `serve`
/// restarts.
///
/// ## What's persisted
///
/// Every enrolled VM's ``MDMDeviceStore/Record`` — UDID,
/// topic, model, OS version, push-token metadata, first /
/// last seen, checkedOut flag. The whole map serialised as
/// an array (deterministic ordering by UDID for
/// reviewability of the file).
///
/// ## When it writes
///
/// `flush(_:)` is called from ``SpooktacularMDMHandler`` after
/// every mutation. The writes are atomic (write to `.tmp`,
/// rename), so a partial crash can't leave a half-baked
/// file. We don't debounce yet — the device store gets at
/// most a few dozen mutations per minute even on a busy
/// host, and JSON-encoding a few records is microseconds.
///
/// ## File layout
///
/// `<storage>/devices.json`. JSON top-level is the array;
/// no envelope, no schema version (yet — when the wire shape
/// needs to change we'll add a `schema` key and migrate).
public struct MDMDeviceStorePersister: Sendable {

    /// Where the JSON lives. Conventionally
    /// `~/.spooktacular/mdm/state/devices.json`.
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Writers

    /// Atomically writes the current contents of the store to
    /// disk. Creates parent directories as needed. Throws on
    /// FS / encoder errors.
    public func flush(_ store: MDMDeviceStore) async throws {
        let records = await store.allEnrolled() + (await store.checkedOutRecords())
        let sorted = records.sorted { $0.udid < $1.udid }
        let data = try Self.encoder.encode(sorted)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Readers

    /// Reads the snapshot off disk and replays every record
    /// into a fresh ``MDMDeviceStore``. Returns an empty
    /// store when the file is absent (first run).
    public func load() async throws -> MDMDeviceStore {
        let store = MDMDeviceStore()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return store
        }
        let data = try Data(contentsOf: fileURL)
        let records = try Self.decoder.decode([MDMDeviceStore.Record].self, from: data)
        for record in records {
            await store.insert(record)
        }
        return store
    }

    /// Snapshot-only reader for CLI use cases (`spook mdm
    /// devices`). Skips the actor reload and just returns the
    /// raw decoded records. Returns an empty array when the
    /// file is absent.
    public func readRecords() throws -> [MDMDeviceStore.Record] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try Self.decoder.decode([MDMDeviceStore.Record].self, from: data)
    }

    // MARK: - Coders

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

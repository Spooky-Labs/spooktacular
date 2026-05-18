import Foundation

/// A tagged event the guest agent pushes to the host on
/// `/api/v1/events/stream` — one NDJSON-encoded frame per
/// event, each frame carrying a topic discriminator and the
/// topic's payload.
///
/// ## Why one stream instead of many
///
/// Every additional push endpoint on the guest agent means:
///
/// - A distinct vsock connection the host must accept, manage,
///   and tear down.
/// - A distinct kqueue/dispatch source, each paying its own
///   idle wakeup cost.
/// - A distinct reconnect state machine on the host (when the
///   stream drops, each one must recover independently).
///
/// Consolidating every push channel onto a single
/// `/api/v1/events/stream` endpoint eliminates all three.
/// Clients subscribe once, demultiplex in user space via this
/// enum, and reconnect once on drop. Matches how GhostVM's
/// `/api/v1/events` multiplexes port-discovery, URL-opened,
/// and log events onto one NDJSON socket — and how Apple's
/// own `os.signpost` stream handles every subsystem through
/// a single consumer.
///
/// ## Wire format
///
/// Each frame on the wire is one NDJSON line with a `topic`
/// discriminator matching a case name:
///
/// ```jsonl
/// {"topic":"stats","data":{"cpuUsage":0.42,"memoryUsedBytes":…}}
/// {"topic":"ports","data":[{"port":8080,"pid":123,"processName":"node"}]}
/// {"topic":"appsFrontmost","data":{"name":"Xcode","bundleID":"com.apple.dt.Xcode",…}}
/// ```
///
/// NDJSON is kept (vs. Track C's binary-plist) because the
/// guest→host vsock stream benefits from being shell-
/// debuggable with `socat vsock:…` + `jq`. The in-process
/// Swift decoder pays a 5× overhead per frame vs. binary
/// plist but the rate is low (~1 Hz aggregate across all
/// topics) so the cost is imperceptible.
public enum GuestEvent: Sendable, Equatable {

    /// Rolling CPU / memory / load / process snapshot. Emitted
    /// by the guest's `AgentStatsHandler` at a cadence it
    /// chooses (currently ~1 Hz). Replaces the legacy
    /// `/api/v1/stats/stream` endpoint.
    case stats(GuestStatsResponse)

    /// Listening-port snapshot. Emitted whenever the guest's
    /// port scanner detects a change from its previous sample,
    /// so a subscriber can drive the host's port-forwarding
    /// UI without polling.
    case ports([GuestPortInfo])

    /// Current frontmost application inside the guest.
    /// Emitted on change, so the host's dock-icon mirroring
    /// (future Track J polish) can update without polling.
    /// Payload is `nil` when the guest has no frontmost app
    /// (rare — Finder always qualifies during normal
    /// operation; the nil case covers Recovery mode).
    case appsFrontmost(GuestAppInfo?)
}

// MARK: - Codable

/// Codable with a `topic`/`data` envelope so new event cases
/// can be added without bumping a version and old clients
/// skip unknown topics gracefully. Matches GhostVM's
/// `/api/v1/events` shape and mirrors `DiscriminatedUnion`
/// patterns in Swift-on-server libraries like Vapor.
extension GuestEvent: Codable {

    private enum CodingKeys: String, CodingKey {
        case topic
        case data
    }

    private enum Topic: String, Codable {
        case stats
        case ports
        case appsFrontmost = "apps.frontmost"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let topic = try container.decode(Topic.self, forKey: .topic)
        switch topic {
        case .stats:
            let payload = try container.decode(GuestStatsResponse.self, forKey: .data)
            self = .stats(payload)
        case .ports:
            let payload = try container.decode([GuestPortInfo].self, forKey: .data)
            self = .ports(payload)
        case .appsFrontmost:
            let payload = try container.decodeIfPresent(GuestAppInfo.self, forKey: .data)
            self = .appsFrontmost(payload)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stats(let payload):
            try container.encode(Topic.stats, forKey: .topic)
            try container.encode(payload, forKey: .data)
        case .ports(let payload):
            try container.encode(Topic.ports, forKey: .topic)
            try container.encode(payload, forKey: .data)
        case .appsFrontmost(let payload):
            try container.encode(Topic.appsFrontmost, forKey: .topic)
            try container.encodeIfPresent(payload, forKey: .data)
        }
    }
}

// MARK: - Topic filter

/// Subscription filter sent to `/api/v1/events/stream` as the
/// `topics` query parameter. The guest agent only emits
/// frames whose topic is in the filter set, so a host that
/// only needs `.stats` doesn't pay the encode cost for
/// `.ports` or `.appsFrontmost` frames.
///
/// Encoded on the wire as a comma-separated list of topic
/// names — simple enough to construct by hand for
/// `socat`/`curl` debugging.
public struct GuestEventFilter: Sendable, Equatable {

    /// Topics the subscriber wants to receive. An empty set
    /// means "all known topics" — the server default, and
    /// also what an ill-formed query string decodes to.
    public let topics: Set<String>

    public init(topics: Set<String>) {
        self.topics = topics
    }

    /// Canonical topic names. Matches the `Topic` rawValues on
    /// `GuestEvent`'s Codable extension so the filter aligns
    /// exactly with the wire-visible discriminators.
    public static let statsTopic = "stats"
    public static let portsTopic = "ports"
    public static let appsFrontmostTopic = "apps.frontmost"

    /// Convenience: a filter that subscribes to everything.
    public static let all = GuestEventFilter(topics: [])

    /// Convenience: stats-only, matching the legacy
    /// `/api/v1/stats/stream` behaviour.
    public static let statsOnly = GuestEventFilter(topics: [statsTopic])

    /// Parses a query-string value like
    /// `stats,ports,apps.frontmost` into a filter. Unknown
    /// topic names are silently dropped — forward-compat so a
    /// newer host talking to an older guest agent doesn't
    /// crash when the agent doesn't recognise a future topic
    /// name.
    public static func parse(_ query: String?) -> GuestEventFilter {
        guard let query, !query.isEmpty else { return .all }
        let tokens = query.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        let valid = Set(tokens.filter {
            $0 == statsTopic || $0 == portsTopic || $0 == appsFrontmostTopic
        })
        return GuestEventFilter(topics: valid)
    }

    /// Returns `true` when the filter permits a given topic.
    public func allows(topic: String) -> Bool {
        topics.isEmpty || topics.contains(topic)
    }
}

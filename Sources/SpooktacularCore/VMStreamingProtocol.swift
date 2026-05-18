import Foundation

/// Wire protocol for the per-VM streaming host API.
///
/// Designed for **server-push at up to 60 Hz** so a SwiftUI view
/// bound to an `@Observable` model can redraw every frame without
/// polling. Key shape decisions:
///
/// - **Length-prefixed framing.** Every frame is
///   `uint32 length || uint8 kind || uint32 topic || payload`.
///   Readers do a single `receive(exactly: 9)` for the header
///   and a single `receive(exactly: length-5)` for the body —
///   no token scanning, no UTF-8 validation.
/// - **Binary property list payload.** `PropertyListEncoder`
///   with `outputFormat = .binary` is Apple's fastest Codable
///   codec on Darwin — a `VMMetricsSnapshot` round-trips in
///   ~25 µs, versus ~120 µs for the same value via
///   `JSONEncoder`. At 60 Hz that's the difference between
///   consuming 0.15 % and 0.7 % of a frame's CPU budget.
/// - **Topic multiplexing.** One connection carries as many
///   subscriptions as the client wants. `.metrics` at 1 Hz,
///   `.ports` event-driven, `.lifecycle` rare — all share the
///   single UDS descriptor. No per-topic connect/accept/TLS
///   dance.
/// - **Monotonic correlation IDs** — the subscription IDs the
///   server assigns are `UInt32` and wrap every 4 billion
///   subscriptions. `nextSubscriptionID()` starts at 1 per
///   connection so frames with `topic == 0` are reserved for
///   control traffic.
///
/// ## Why not NDJSON / REST / WebSocket / gRPC / XPC?
///
/// | Alternative | Why not |
/// |---|---|
/// | NDJSON over UDS | UTF-8 line-scanning fixes overhead at ~5× binary plist |
/// | REST over UDS (HTTP/1.1) | Connection-per-request defeats server-push entirely |
/// | WebSocket | Requires an HTTP upgrade dance + framing we'd reimplement |
/// | gRPC / protobuf | Drags in a 2 MB runtime for a local-only transport |
/// | XPC | Great for typed Swift clients, but not reachable from `curl`/`python` for headless automation |
///
/// UDS + length-prefix + binary plist is the minimum primitive
/// that satisfies all four use cases (SwiftUI, CLI, curl, python)
/// without introducing a new runtime dependency.
///
/// ## Threat model
///
/// The socket lives at
/// `~/Library/Application Support/Spooktacular/api/<vm>.sock`
/// with `0700` on the directory so only the current user can
/// connect. The server additionally captures `LOCAL_PEERPID` on
/// accept and records it on every audited frame so operator-
/// attributable events survive the socket boundary.
public enum VMStreamingProtocol {

    /// Protocol version byte embedded in every control frame.
    /// Bump on any backward-incompatible wire change.
    public static let version: UInt8 = 1

    /// Magic prefix confirming both peers are speaking this
    /// protocol. Four bytes = one SIMD128 compare on Apple
    /// Silicon.
    public static let magic: UInt32 = 0x5350_4B53 // "SPKS"

    /// Header length (magic + length + kind + topic). The
    /// remaining payload is `length - 5` bytes on the wire
    /// because `length` counts everything *after* itself.
    public static let headerByteCount: Int = 13

    /// Kinds of frame that can cross the wire. `kind == 0`
    /// (Reserved) is never sent; readers that see it can treat
    /// the connection as corrupt.
    public enum FrameKind: UInt8, Sendable {
        /// Unused; detects protocol-level corruption.
        case reserved       = 0
        /// Client → Server: "start sending `topic` events".
        case subscribe      = 1
        /// Client → Server: "stop sending `topic` events".
        case unsubscribe    = 2
        /// Server → Client: event payload for a subscribed topic.
        case event          = 3
        /// Server → Client: subscription accepted; `topic` is
        /// the server-assigned topic ID.
        case ack            = 4
        /// Server → Client: subscription failed or stream
        /// ended; payload is a `VMStreamingError` plist.
        case error          = 5
        /// Server → Client: heartbeat (zero-payload). Sent
        /// every ``heartbeatInterval`` seconds so clients can
        /// detect a wedged connection without parsing real
        /// events.
        case heartbeat      = 6
    }

    /// Topics a client can subscribe to. Names match the
    /// server-side publishers one-for-one so the binding is
    /// legible at a glance.
    public enum Topic: String, Sendable, Codable, CaseIterable {
        /// Rolling CPU / memory / load / process snapshots.
        /// Published at whatever cadence the guest agent's
        /// `/api/v1/stats/stream` produces (currently ~1 Hz;
        /// the API doesn't require it).
        case metrics
        /// VM lifecycle transitions (starting, running,
        /// pausing, paused, resuming, stopped, error). One
        /// frame per transition.
        case lifecycle
        /// Listening-port discoveries / retirements.
        case ports
        /// Host-agent round-trip latency samples.
        case health
        /// Guest OSLog stream (future work — reserved now so
        /// the topic enum is stable).
        case log
    }

    /// Heartbeat cadence. Three seconds gives the client a
    /// useful liveness signal (5× the 60 fps frame budget
    /// scaled to a "I'm still here" beat) without spending
    /// wakeups on idle connections.
    public static let heartbeatInterval: Duration = .seconds(3)
}

// MARK: - Control payloads

/// Client-originated subscription request. Sent on frames of
/// kind ``VMStreamingProtocol/FrameKind/subscribe`` with
/// `topic == 0` (the control channel). Server responds with an
/// `ack` carrying the server-assigned topic ID that future
/// events on this subscription will use.
public struct VMStreamSubscribeRequest: Sendable, Codable, Equatable {
    public let topic: VMStreamingProtocol.Topic

    public init(topic: VMStreamingProtocol.Topic) {
        self.topic = topic
    }
}

/// Server-side error delivered on frame kind ``VMStreamingProtocol/FrameKind/error``.
public struct VMStreamingError: Sendable, Codable, Error, Equatable, LocalizedError {
    public let code: Code
    public let reason: String

    /// Wire-level error codes for the streaming protocol.
    ///
    /// Raw values use `snake_case` so the on-wire JSON is
    /// stable regardless of Swift identifier style changes,
    /// and so external consumers (UDS subscribers written in
    /// Go, Python, Node) parse the enum with their idiomatic
    /// conventions without a naming shim.
    public enum Code: String, Sendable, Codable {
        case unknownTopic = "unknown_topic"
        case subscriptionDenied = "subscription_denied"
        case vmStopped = "vm_stopped"
        case protocolMismatch = "protocol_mismatch"
        case internalError = "internal_error"
    }

    public init(code: Code, reason: String) {
        self.code = code
        self.reason = reason
    }

    public var errorDescription: String? {
        "\(code.rawValue): \(reason)"
    }
}

// MARK: - Event payloads

/// Live VM metrics frame published on ``VMStreamingProtocol/Topic/metrics``.
/// Field layout matches `GuestStatsResponse` so this is a cheap
/// re-encode on the server side.
public struct VMMetricsSnapshot: Sendable, Codable, Equatable {
    public let at: Date
    public let cpuUsage: Double?
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let loadAverage1m: Double
    public let processCount: Int
    public let uptime: TimeInterval

    public init(
        at: Date,
        cpuUsage: Double?,
        memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64,
        loadAverage1m: Double,
        processCount: Int,
        uptime: TimeInterval
    ) {
        self.at = at
        self.cpuUsage = cpuUsage
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.loadAverage1m = loadAverage1m
        self.processCount = processCount
        self.uptime = uptime
    }

    public var memoryUsageFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
}

/// VM lifecycle frame published on ``VMStreamingProtocol/Topic/lifecycle``.
public struct VMLifecycleEvent: Sendable, Codable, Equatable {
    public let at: Date
    public let state: String   // rawValue of VirtualMachineState
    public let reason: String?

    public init(at: Date, state: String, reason: String? = nil) {
        self.at = at
        self.state = state
        self.reason = reason
    }
}

/// Listening-port frame published on ``VMStreamingProtocol/Topic/ports``.
public struct VMPortsSnapshot: Sendable, Codable, Equatable {
    public let at: Date
    public let ports: [Entry]

    public struct Entry: Sendable, Codable, Equatable {
        public let port: UInt16
        public let processName: String
        public init(port: UInt16, processName: String) {
            self.port = port
            self.processName = processName
        }
    }

    public init(at: Date, ports: [Entry]) {
        self.at = at
        self.ports = ports
    }
}

/// Host→guest round-trip measurement, ``VMStreamingProtocol/Topic/health``.
public struct VMHealthSample: Sendable, Codable, Equatable {
    public let at: Date
    public let latencyMs: Double?
    public init(at: Date, latencyMs: Double?) {
        self.at = at
        self.latencyMs = latencyMs
    }
}

// MARK: - Frame encoding / decoding

/// Binary-plist Codable codec used for all payloads on the wire.
///
/// Single instance so callers don't pay repeated
/// encoder-construction cost at 60 Hz. Both encoder and
/// decoder are `Sendable`-safe — `PropertyListEncoder` /
/// `PropertyListDecoder` don't mutate shared state across
/// encodes. The `@unchecked` is unsound in theory but matches
/// Apple's own usage pattern and avoids a gratuitous lock on
/// the hot path.
public enum VMStreamingCodec {
    /// Shared binary-plist encoder used for every outbound
    /// stream frame. Configured with `.binary` output so the
    /// wire bytes are compact and byte-stable across runs.
    public static let encoder: PropertyListEncoder = {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return e
    }()

    /// Shared binary-plist decoder used for every inbound
    /// stream frame. `PropertyListDecoder` is thread-safe for
    /// concurrent reads so the single static instance covers
    /// all consumers.
    public static let decoder = PropertyListDecoder()

    /// Serializes a Codable payload to the binary-plist bytes
    /// that go on the wire after the frame header.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    /// Deserializes payload bytes back to a typed value.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

/// A single frame on the wire. Helper for tests and for the
/// server's outbound-frame queue.
public struct VMStreamingFrame: Sendable, Equatable {
    public let kind: VMStreamingProtocol.FrameKind
    public let topic: UInt32
    public let payload: Data

    public init(kind: VMStreamingProtocol.FrameKind, topic: UInt32, payload: Data = Data()) {
        self.kind = kind
        self.topic = topic
        self.payload = payload
    }

    /// Encodes this frame into the length-prefixed wire
    /// format. Layout (all integers big-endian):
    ///
    /// | Bytes | Field      | Notes |
    /// |-------|------------|-------|
    /// | 0-3   | magic      | `VMStreamingProtocol.magic` |
    /// | 4-7   | length     | Bytes in kind+topic+payload |
    /// | 8     | kind       | ``VMStreamingProtocol/FrameKind`` rawValue |
    /// | 9-12  | topic      | Subscription ID, or 0 for control |
    /// | 13…   | payload    | `length - 5` bytes, binary plist |
    ///
    /// Writers can concatenate a queue of `encoded()` buffers
    /// and hand them to `NWConnection.send(content:)` in one
    /// system call.
    public func encoded() -> Data {
        var out = Data(capacity: VMStreamingProtocol.headerByteCount + payload.count)
        out.appendBigEndian(VMStreamingProtocol.magic)
        out.appendBigEndian(UInt32(5 + payload.count))
        out.append(kind.rawValue)
        out.appendBigEndian(topic)
        out.append(payload)
        return out
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { self.append(contentsOf: $0) }
    }
}

/// Parses a single frame from the head of `buffer`, consuming
/// the frame's bytes on success. Returns `nil` when the buffer
/// doesn't yet hold a complete frame (the reader should
/// `receive` more bytes). Throws on protocol corruption.
public func parseVMStreamingFrame(from buffer: inout Data) throws -> VMStreamingFrame? {
    guard buffer.count >= VMStreamingProtocol.headerByteCount else { return nil }

    let magic = buffer.readBigEndianUInt32(at: 0)
    guard magic == VMStreamingProtocol.magic else {
        throw VMStreamingError(code: .protocolMismatch, reason: "magic bytes mismatch")
    }

    let length = Int(buffer.readBigEndianUInt32(at: 4))
    // length counts everything after the length field, so the
    // total frame size on the wire is (magic + length field +
    // body) = 8 + length.
    let totalFrameSize = 8 + length
    guard buffer.count >= totalFrameSize else { return nil }

    let kindByte = buffer[buffer.startIndex + 8]
    guard let kind = VMStreamingProtocol.FrameKind(rawValue: kindByte) else {
        throw VMStreamingError(code: .protocolMismatch, reason: "unknown frame kind \(kindByte)")
    }
    let topic = buffer.readBigEndianUInt32(at: 9)
    let payloadStart = buffer.startIndex + VMStreamingProtocol.headerByteCount
    let payloadEnd = buffer.startIndex + totalFrameSize
    let payload = Data(buffer[payloadStart..<payloadEnd])

    buffer.removeSubrange(buffer.startIndex..<payloadEnd)

    return VMStreamingFrame(kind: kind, topic: topic, payload: payload)
}

private extension Data {
    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let idx = self.startIndex + offset
        return UInt32(self[idx]) << 24
            | UInt32(self[idx + 1]) << 16
            | UInt32(self[idx + 2]) << 8
            | UInt32(self[idx + 3])
    }
}

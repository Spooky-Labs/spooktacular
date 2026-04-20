import Foundation

/// Typed union of every message that flows on the Apple-native
/// host ↔ guest vsock channel.
///
/// ## Why one enum
///
/// `VZVirtioSocketListener` gives us a single bidirectional
/// stream per VM. Rather than multiplex HTTP-over-vsock plus a
/// separate event channel (which is what the old agent did),
/// everything rides the same connection as typed `Codable`
/// frames encoded length-prefixed by ``AgentFrameCodec``.
///
/// ## Three categories
///
/// - **Events** — guest → host, one-way pushes. No
///   `requestID`. Example: ``stats(_:)`` emitted once per
///   second by the agent.
/// - **Requests** — host → guest, carry a fresh `requestID`.
///   The host parks a continuation keyed by the ID; the
///   reader task wakes it when the matching response arrives.
/// - **Responses** — guest → host, echo the caller's
///   `requestID`. Exactly one response per request (even
///   errors travel as ``errorResponse(requestID:_:)``).
///
/// ## Wire shape
///
/// On the wire each frame encodes as:
///
/// ```json
/// {"kind": "statsEvent", "payload": { ... }}
/// {"kind": "execRequest", "requestID": "UUID-string", "payload": { ... }}
/// {"kind": "execResponse", "requestID": "UUID-string", "payload": { ... }}
/// ```
///
/// The body is then wrapped by ``AgentFrameCodec`` in a 4-byte
/// big-endian length prefix so both sides can delineate frames
/// on the raw vsock byte stream.
public enum AgentFrame: Codable, Sendable, Equatable {

    // MARK: - Events (guest → host, one-way)

    /// Rolling CPU / memory / load / process snapshot, emitted
    /// at ~1 Hz by the agent.
    case statsEvent(GuestStatsResponse)

    /// Listening-port snapshot, emitted on change.
    case portsEvent([GuestPortInfo])

    /// Current frontmost app (macOS guest only; Linux never
    /// emits this). `nil` payload when no app is frontmost
    /// (Recovery mode, login window).
    case appsFrontmostEvent(GuestAppInfo?)

    /// Guest clipboard changed (macOS or wayland/xclip on Linux).
    /// Carries the new text so the host can mirror it without a
    /// follow-up read.
    case clipboardChangedEvent(GuestClipboardContent)

    /// Guest opened a URL (e.g., `open https://example.com`).
    /// Lets the host hand the URL back to the host browser for
    /// seamless "click in VM, open outside" handoff.
    case urlOpenedEvent(URLOpenedEvent)

    /// Free-form log line for agent-side observability. The
    /// host forwards these into `os_log` / journald as
    /// appropriate.
    case logEvent(LogEvent)

    // MARK: - Requests (host → guest, correlated)

    case execRequest(requestID: UUID, GuestExecRequest)
    case breakGlassExecRequest(requestID: UUID, BreakGlassExecRequest)
    case clipboardGetRequest(requestID: UUID)
    case clipboardSetRequest(requestID: UUID, GuestClipboardContent)
    case appsListRequest(requestID: UUID)
    case appsFrontmostRequest(requestID: UUID)
    case appsLaunchRequest(requestID: UUID, GuestAppRequest)
    case appsQuitRequest(requestID: UUID, GuestAppRequest)
    case portsListRequest(requestID: UUID)
    case healthRequest(requestID: UUID)
    case tunnelOpenRequest(requestID: UUID, TunnelOpenRequest)

    // MARK: - Responses (guest → host, correlated)

    case execResponse(requestID: UUID, GuestExecResponse)
    case clipboardGetResponse(requestID: UUID, GuestClipboardContent)
    case clipboardSetResponse(requestID: UUID)
    case appsListResponse(requestID: UUID, [GuestAppInfo])
    case appsFrontmostResponse(requestID: UUID, GuestAppInfo?)
    case appsLaunchResponse(requestID: UUID)
    case appsQuitResponse(requestID: UUID)
    case portsListResponse(requestID: UUID, [GuestPortInfo])
    case healthResponse(requestID: UUID, GuestHealthResponse)
    case tunnelOpenResponse(requestID: UUID, TunnelOpenResponse)

    /// Error response for any request the guest couldn't honor.
    /// Preserves the caller's `requestID` so the host's
    /// continuation resumes with a `throw`.
    case errorResponse(requestID: UUID, AgentError)

    // MARK: - Correlation

    /// Returns the request ID for request/response frames,
    /// `nil` for pure events. Used by the host reader to
    /// decide whether to wake a parked continuation or yield
    /// into the event stream.
    public var requestID: UUID? {
        switch self {
        case .statsEvent, .portsEvent, .appsFrontmostEvent,
             .clipboardChangedEvent, .urlOpenedEvent, .logEvent:
            return nil
        case .execRequest(let id, _),
             .breakGlassExecRequest(let id, _),
             .clipboardGetRequest(let id),
             .clipboardSetRequest(let id, _),
             .appsListRequest(let id),
             .appsFrontmostRequest(let id),
             .appsLaunchRequest(let id, _),
             .appsQuitRequest(let id, _),
             .portsListRequest(let id),
             .healthRequest(let id),
             .tunnelOpenRequest(let id, _),
             .execResponse(let id, _),
             .clipboardGetResponse(let id, _),
             .clipboardSetResponse(let id),
             .appsListResponse(let id, _),
             .appsFrontmostResponse(let id, _),
             .appsLaunchResponse(let id),
             .appsQuitResponse(let id),
             .portsListResponse(let id, _),
             .healthResponse(let id, _),
             .tunnelOpenResponse(let id, _),
             .errorResponse(let id, _):
            return id
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case requestID
        case payload
    }

    private enum Kind: String, Codable {
        case statsEvent
        case portsEvent
        case appsFrontmostEvent
        case clipboardChangedEvent
        case urlOpenedEvent
        case logEvent

        case execRequest
        case breakGlassExecRequest
        case clipboardGetRequest
        case clipboardSetRequest
        case appsListRequest
        case appsFrontmostRequest
        case appsLaunchRequest
        case appsQuitRequest
        case portsListRequest
        case healthRequest
        case tunnelOpenRequest

        case execResponse
        case clipboardGetResponse
        case clipboardSetResponse
        case appsListResponse
        case appsFrontmostResponse
        case appsLaunchResponse
        case appsQuitResponse
        case portsListResponse
        case healthResponse
        case tunnelOpenResponse
        case errorResponse
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let id = try container.decodeIfPresent(UUID.self, forKey: .requestID)
        switch kind {
        case .statsEvent:
            self = .statsEvent(try container.decode(GuestStatsResponse.self, forKey: .payload))
        case .portsEvent:
            self = .portsEvent(try container.decode([GuestPortInfo].self, forKey: .payload))
        case .appsFrontmostEvent:
            self = .appsFrontmostEvent(try container.decodeIfPresent(GuestAppInfo.self, forKey: .payload))
        case .clipboardChangedEvent:
            self = .clipboardChangedEvent(try container.decode(GuestClipboardContent.self, forKey: .payload))
        case .urlOpenedEvent:
            self = .urlOpenedEvent(try container.decode(URLOpenedEvent.self, forKey: .payload))
        case .logEvent:
            self = .logEvent(try container.decode(LogEvent.self, forKey: .payload))
        case .execRequest:
            self = .execRequest(requestID: try Self.requireID(id), try container.decode(GuestExecRequest.self, forKey: .payload))
        case .breakGlassExecRequest:
            self = .breakGlassExecRequest(requestID: try Self.requireID(id), try container.decode(BreakGlassExecRequest.self, forKey: .payload))
        case .clipboardGetRequest:
            self = .clipboardGetRequest(requestID: try Self.requireID(id))
        case .clipboardSetRequest:
            self = .clipboardSetRequest(requestID: try Self.requireID(id), try container.decode(GuestClipboardContent.self, forKey: .payload))
        case .appsListRequest:
            self = .appsListRequest(requestID: try Self.requireID(id))
        case .appsFrontmostRequest:
            self = .appsFrontmostRequest(requestID: try Self.requireID(id))
        case .appsLaunchRequest:
            self = .appsLaunchRequest(requestID: try Self.requireID(id), try container.decode(GuestAppRequest.self, forKey: .payload))
        case .appsQuitRequest:
            self = .appsQuitRequest(requestID: try Self.requireID(id), try container.decode(GuestAppRequest.self, forKey: .payload))
        case .portsListRequest:
            self = .portsListRequest(requestID: try Self.requireID(id))
        case .healthRequest:
            self = .healthRequest(requestID: try Self.requireID(id))
        case .tunnelOpenRequest:
            self = .tunnelOpenRequest(requestID: try Self.requireID(id), try container.decode(TunnelOpenRequest.self, forKey: .payload))
        case .execResponse:
            self = .execResponse(requestID: try Self.requireID(id), try container.decode(GuestExecResponse.self, forKey: .payload))
        case .clipboardGetResponse:
            self = .clipboardGetResponse(requestID: try Self.requireID(id), try container.decode(GuestClipboardContent.self, forKey: .payload))
        case .clipboardSetResponse:
            self = .clipboardSetResponse(requestID: try Self.requireID(id))
        case .appsListResponse:
            self = .appsListResponse(requestID: try Self.requireID(id), try container.decode([GuestAppInfo].self, forKey: .payload))
        case .appsFrontmostResponse:
            self = .appsFrontmostResponse(requestID: try Self.requireID(id), try container.decodeIfPresent(GuestAppInfo.self, forKey: .payload))
        case .appsLaunchResponse:
            self = .appsLaunchResponse(requestID: try Self.requireID(id))
        case .appsQuitResponse:
            self = .appsQuitResponse(requestID: try Self.requireID(id))
        case .portsListResponse:
            self = .portsListResponse(requestID: try Self.requireID(id), try container.decode([GuestPortInfo].self, forKey: .payload))
        case .healthResponse:
            self = .healthResponse(requestID: try Self.requireID(id), try container.decode(GuestHealthResponse.self, forKey: .payload))
        case .tunnelOpenResponse:
            self = .tunnelOpenResponse(requestID: try Self.requireID(id), try container.decode(TunnelOpenResponse.self, forKey: .payload))
        case .errorResponse:
            self = .errorResponse(requestID: try Self.requireID(id), try container.decode(AgentError.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func emit<P: Encodable>(_ kind: Kind, _ id: UUID?, _ payload: P?) throws {
            try container.encode(kind, forKey: .kind)
            if let id { try container.encode(id, forKey: .requestID) }
            if let payload { try container.encode(payload, forKey: .payload) }
        }
        switch self {
        case .statsEvent(let p):                   try emit(.statsEvent,                nil, p)
        case .portsEvent(let p):                   try emit(.portsEvent,                nil, p)
        case .appsFrontmostEvent(let p):           try emit(.appsFrontmostEvent,        nil, p)
        case .clipboardChangedEvent(let p):        try emit(.clipboardChangedEvent,     nil, p)
        case .urlOpenedEvent(let p):               try emit(.urlOpenedEvent,            nil, p)
        case .logEvent(let p):                     try emit(.logEvent,                  nil, p)
        case .execRequest(let id, let p):          try emit(.execRequest,                id, p)
        case .breakGlassExecRequest(let id, let p):try emit(.breakGlassExecRequest,      id, p)
        case .clipboardGetRequest(let id):         try emit(.clipboardGetRequest,        id, Optional<Empty>.none)
        case .clipboardSetRequest(let id, let p):  try emit(.clipboardSetRequest,        id, p)
        case .appsListRequest(let id):             try emit(.appsListRequest,            id, Optional<Empty>.none)
        case .appsFrontmostRequest(let id):        try emit(.appsFrontmostRequest,       id, Optional<Empty>.none)
        case .appsLaunchRequest(let id, let p):    try emit(.appsLaunchRequest,          id, p)
        case .appsQuitRequest(let id, let p):      try emit(.appsQuitRequest,            id, p)
        case .portsListRequest(let id):            try emit(.portsListRequest,           id, Optional<Empty>.none)
        case .healthRequest(let id):               try emit(.healthRequest,              id, Optional<Empty>.none)
        case .tunnelOpenRequest(let id, let p):    try emit(.tunnelOpenRequest,          id, p)
        case .execResponse(let id, let p):         try emit(.execResponse,               id, p)
        case .clipboardGetResponse(let id, let p): try emit(.clipboardGetResponse,       id, p)
        case .clipboardSetResponse(let id):        try emit(.clipboardSetResponse,       id, Optional<Empty>.none)
        case .appsListResponse(let id, let p):     try emit(.appsListResponse,           id, p)
        case .appsFrontmostResponse(let id, let p):try emit(.appsFrontmostResponse,      id, p)
        case .appsLaunchResponse(let id):          try emit(.appsLaunchResponse,         id, Optional<Empty>.none)
        case .appsQuitResponse(let id):            try emit(.appsQuitResponse,           id, Optional<Empty>.none)
        case .portsListResponse(let id, let p):    try emit(.portsListResponse,          id, p)
        case .healthResponse(let id, let p):       try emit(.healthResponse,             id, p)
        case .tunnelOpenResponse(let id, let p):   try emit(.tunnelOpenResponse,         id, p)
        case .errorResponse(let id, let p):        try emit(.errorResponse,              id, p)
        }
    }

    /// Sentinel used when the payload slot is genuinely empty
    /// (request frames like `healthRequest` carry no body).
    private struct Empty: Encodable {}

    private static func requireID(_ id: UUID?) throws -> UUID {
        guard let id else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "frame kind requires a requestID"
                )
            )
        }
        return id
    }
}

// MARK: - Supporting DTOs new for the Apple-native channel

/// A URL the guest asked to open. The host bridges this into
/// `NSWorkspace.shared.open(_:)` so a click-to-open inside the
/// VM surfaces in the user's default browser on the host.
public struct URLOpenedEvent: Codable, Sendable, Equatable {
    public let url: URL
    public let originatingApp: String?

    public init(url: URL, originatingApp: String?) {
        self.url = url
        self.originatingApp = originatingApp
    }
}

/// One log line forwarded from the guest. Level maps onto
/// `os_log`'s `OSLogType` on the host so agent logs show up in
/// Console.app under the same subsystem as the rest of
/// Spooktacular.
public struct LogEvent: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable, Equatable {
        case debug, info, notice, warning, error, fault
    }
    public let level: Level
    public let message: String
    public let timestamp: Date

    public init(level: Level, message: String, timestamp: Date) {
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }
}

/// Break-glass-ticket-gated exec. Carries the exec body plus the
/// signed ticket the host minted via `spook break-glass issue`.
public struct BreakGlassExecRequest: Codable, Sendable, Equatable {
    public let command: String
    public let timeout: Int?
    public let ticket: String
    public init(command: String, timeout: Int?, ticket: String) {
        self.command = command
        self.timeout = timeout
        self.ticket = ticket
    }
}

/// Opens a TCP-over-vsock tunnel to a host port. After the guest
/// acknowledges with a ``TunnelOpenResponse``, subsequent raw
/// bytes on the same vsock connection splice to a guest
/// `127.0.0.1:port` socket.
public struct TunnelOpenRequest: Codable, Sendable, Equatable {
    public let guestPort: UInt16
    public init(guestPort: UInt16) { self.guestPort = guestPort }
}

public struct TunnelOpenResponse: Codable, Sendable, Equatable {
    public let accepted: Bool
    public init(accepted: Bool) { self.accepted = accepted }
}

/// Typed agent-side error carried in ``AgentFrame/errorResponse(requestID:_:)``.
public struct AgentError: Codable, Sendable, Equatable, Error {
    public enum Code: String, Codable, Sendable, Equatable {
        case unsupported
        case notAuthorized
        case invalidRequest
        case guestUnavailable
        case timedOut
        case internalFailure
    }
    public let code: Code
    public let message: String
    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

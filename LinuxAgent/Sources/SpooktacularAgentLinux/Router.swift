import Foundation

/// Minimal HTTP router. Shape-compatible with the macOS agent's
/// subset of endpoints the host's chart + port panel actually
/// consume:
///
///   GET /health                          → `{"ok":true}`
///   GET /api/v1/stats                    → one-shot `GuestStatsResponse`
///   GET /api/v1/events/stream?topics=…   → NDJSON event stream
///   GET /api/v1/ports                    → `[GuestPortInfo]`
///
/// Anything else (exec, clipboard, apps, break-glass) returns
/// 404 — those are macOS-specific and the Linux agent genuinely
/// cannot serve them.
final class Router {

    enum RouteResult {
        case response(status: String, contentType: String, body: Data)
        case stream(EventStream)
        case notFound
    }

    private let statsActor: StatsCoordinator

    init(statsActor: StatsCoordinator) {
        self.statsActor = statsActor
    }

    func route(method: String, path: String, query: String?) -> RouteResult {
        guard method == "GET" else { return .notFound }
        switch path {
        case "/health":
            return .response(
                status: "200 OK",
                contentType: "application/json",
                body: Data(#"{"ok":true}"#.utf8)
            )
        case "/api/v1/stats":
            let frame = statsActor.snapshot()
            let body = (try? JSONEncoder().encode(frame)) ?? Data()
            return .response(status: "200 OK", contentType: "application/json", body: body)
        case "/api/v1/ports":
            let entries = LinuxPortScanner.scan()
            let body = (try? JSONEncoder().encode(entries)) ?? Data()
            return .response(status: "200 OK", contentType: "application/json", body: body)
        case "/api/v1/events/stream":
            let topics = parseTopics(query: query)
            return .stream(EventStream(statsActor: statsActor, topics: topics))
        default:
            return .notFound
        }
    }

    /// `?topics=stats,ports` → `["stats", "ports"]`. Empty or
    /// missing means "subscribe to everything the server knows".
    private func parseTopics(query: String?) -> Set<String> {
        guard let query else { return [] }
        for piece in query.split(separator: "&") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == "topics" else { continue }
            return Set(kv[1].split(separator: ",").map { String($0) })
        }
        return []
    }
}

/// Streaming event pump. Emits one JSON line per tick, matching
/// the macOS agent's `GuestEvent` envelope (`{"topic": "stats",
/// "data": {...}}`).
///
/// Runs on the calling thread (ConnectionHandler already runs
/// per-connection), so it's a simple sleep loop. Cancellation is
/// implicit: once the host disconnects, `write` returns <= 0 and
/// the ConnectionHandler drops out of its serve loop.
final class EventStream {

    private let statsActor: StatsCoordinator
    private let topics: Set<String>

    init(statsActor: StatsCoordinator, topics: Set<String>) {
        self.statsActor = statsActor
        self.topics = topics
    }

    func pump(writer: (Data) -> Void) {
        while true {
            if topics.isEmpty || topics.contains("stats") {
                let frame = statsActor.snapshot()
                let line = Self.envelope(topic: "stats", payload: frame) + Data("\n".utf8)
                writer(line)
            }
            if topics.isEmpty || topics.contains("ports") {
                let ports = LinuxPortScanner.scan()
                let line = Self.envelope(topic: "ports", payload: ports) + Data("\n".utf8)
                writer(line)
            }
            // 1 Hz cadence matches the macOS agent's
            // AgentStatsHandler loop and the host chart's
            // sampling assumptions.
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private static func envelope<T: Encodable>(topic: String, payload: T) -> Data {
        struct Envelope<P: Encodable>: Encodable {
            let topic: String
            let data: P
        }
        return (try? JSONEncoder().encode(Envelope(topic: topic, data: payload))) ?? Data()
    }
}

/// Thread-safe wrapper around the `LinuxStatsSampler` — the
/// sampler holds a previous-sample cache, so it must be accessed
/// under a lock if multiple connections call it concurrently.
final class StatsCoordinator: @unchecked Sendable {
    private var sampler = LinuxStatsSampler()
    private let lock = NSLock()

    func snapshot() -> LinuxStatsSampler.StatsFrame {
        lock.lock(); defer { lock.unlock() }
        return sampler.sample()
    }
}

import Foundation

/// Shared outbound HTTPS client for every Spooktacular
/// integration that calls a remote service. Replaces the
/// scattered, case-by-case `URLSession.shared` +
/// ad-hoc-request-builder pattern that crept into
/// `WebhookAuditSink`, the EBS bridge (Track M), and the
/// controller client with one typed pipeline.
///
/// ## Design goals
///
/// - **Typed in, typed out.** Callers hand in a Codable
///   request body and a response type; the client handles
///   encode / send / decode.
/// - **Pluggable signing.** SigV4 for AWS, HMAC-SHA256 for
///   webhook audit sinks, per-request P-256 ECDSA for the
///   controller API — each is a ``RequestSigner``, chosen
///   per-call or set per-client instance.
/// - **Zero `URLSession` leakage.** Callers never touch
///   `URLSession` / `URLRequest` / `URLResponse` directly.
///   That lets ``HTTPSClient`` swap to
///   `NWConnection`-backed transports (for QUIC via Track L)
///   without rewriting call sites.
/// - **Deterministic retry + timeout policy.** One place to
///   adjust them; one place to audit them.
/// - **Testable.** The protocol-level abstraction lets tests
///   inject a stub client that returns canned bytes without
///   monkey-patching `URLProtocol`.
///
/// ## Apple APIs
///
/// - [`URLSession`](https://developer.apple.com/documentation/foundation/urlsession)
///   — default transport in ``URLSessionHTTPSClient``.
/// - [`URLSession.data(for:)`](https://developer.apple.com/documentation/foundation/urlsession/3767353-data)
///   — async/await send.
/// - [`URLSessionConfiguration`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration)
///   — timeouts, TLS pinning, proxy policy.
public protocol HTTPSClient: Sendable {

    /// Sends `request` and decodes the response to `Response`.
    /// Throws ``HTTPSError`` on transport, status, or decode
    /// failure.
    func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ request: HTTPSRequest<Request>,
        decoding: Response.Type
    ) async throws -> Response

    /// Sends `request` with an empty body and decodes the
    /// response. Convenience for `GET` / `DELETE` calls.
    func send<Response: Decodable & Sendable>(
        _ request: HTTPSRequest<EmptyBody>,
        decoding: Response.Type
    ) async throws -> Response

    /// Sends `request` and discards the response body.
    /// Convenience for fire-and-forget mutations where only
    /// the status code matters.
    func send<Request: Encodable & Sendable>(
        _ request: HTTPSRequest<Request>
    ) async throws

    /// Sends `request` and returns the raw response body
    /// without running it through `JSONDecoder`. The escape
    /// hatch for endpoints that don't speak JSON — e.g.,
    /// AWS EBS's `GetSnapshotBlock` returns 512 KiB of raw
    /// block bytes.
    func sendRaw<Request: Encodable & Sendable>(
        _ request: HTTPSRequest<Request>
    ) async throws -> (data: Data, headers: [String: String])
}

// MARK: - Typed request

/// A fully-specified outbound HTTPS request. Immutable value
/// type — the signer in ``URLSessionHTTPSClient`` consumes it
/// without mutating. Parameterised over the body type so the
/// compiler can enforce that `POST`s without a body don't
/// even compile.
public struct HTTPSRequest<Body: Encodable & Sendable>: Sendable {

    /// HTTP verb. Scoped to a finite enum so typos and
    /// accidental lowercase strings fail at compile time.
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
        case patch = "PATCH"
    }

    public let method: Method
    public let url: URL
    public let headers: [String: String]
    public let body: Body?
    public let signer: (any RequestSigner)?

    /// Per-request timeout override. `nil` means "use the
    /// client's default" (``URLSessionHTTPSClient.timeout``).
    public let timeout: Duration?

    public init(
        _ method: Method,
        url: URL,
        headers: [String: String] = [:],
        body: Body? = nil,
        signer: (any RequestSigner)? = nil,
        timeout: Duration? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.signer = signer
        self.timeout = timeout
    }
}

/// Zero-byte body sentinel for requests that have no payload.
/// Conforms to `Codable & Sendable` so the same `send<Body>`
/// signature handles both body and body-less calls, and
/// tests can round-trip it to verify.
public struct EmptyBody: Codable, Sendable, Equatable {
    public init() {}
}

// MARK: - Signer protocol

/// Strategy for signing an outbound `URLRequest` before it
/// hits the wire. Implementations include:
///
/// - ``SigV4Signer`` — AWS SigV4 (HMAC-SHA256).
/// - ``HMACRequestSigner`` — symmetric HMAC-SHA256 (webhook
///   audit sinks).
/// - ``P256RequestSigner`` — per-request P-256 ECDSA
///   (controller API, matches the host-identity headers the
///   guest agent verifies).
///
/// Callers set a default signer on the client or override
/// per-request via ``HTTPSRequest/signer``. Per-request
/// overrides are the right shape when one process talks to
/// multiple services under different auth shapes (e.g., AWS
/// STS + webhook audit + Spooktacular controller all from
/// one daemon).
public protocol RequestSigner: Sendable {

    /// Signs `request` in place. May mutate headers, path
    /// query parameters, or the body (e.g., to add a
    /// body-hash header SigV4 requires). Runs asynchronously
    /// so signers that need to call out (e.g., fetch a fresh
    /// STS key or mint a new OIDC token) don't block the
    /// caller's task.
    func sign(_ request: inout URLRequest) async throws
}

// MARK: - Errors

/// Categorized failures callers can switch on.
public enum HTTPSError: Error, LocalizedError, Sendable {
    /// Transport-level failure (DNS, TCP, TLS). `underlying`
    /// carries the raw `URLError`.
    case transport(underlying: Error)

    /// Non-2xx response. Includes the status and body so
    /// callers can surface AWS-style error details.
    case status(code: Int, body: Data)

    /// Response body couldn't be decoded to the requested
    /// Codable type. Usually means the server returned an
    /// error envelope we haven't modeled yet.
    case decode(underlying: Error)

    /// Request encoding failed — malformed body, impossible
    /// header, etc. Almost always a programmer error.
    case encode(underlying: Error)

    /// The signer threw.
    case signing(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .transport(let err):
            return "HTTPS transport error: \(err.localizedDescription)"
        case .status(let code, let body):
            let snippet = String(data: body.prefix(500), encoding: .utf8) ?? "<binary>"
            return "HTTPS status \(code): \(snippet)"
        case .decode(let err):
            return "HTTPS decode error: \(err.localizedDescription)"
        case .encode(let err):
            return "HTTPS encode error: \(err.localizedDescription)"
        case .signing(let err):
            return "HTTPS request signing error: \(err.localizedDescription)"
        }
    }
}

// MARK: - Default implementation

/// `URLSession`-backed ``HTTPSClient``. The default everyone
/// should use unless they're actively testing a replacement
/// transport.
public final class URLSessionHTTPSClient: HTTPSClient, @unchecked Sendable {

    /// Default per-request timeout. 30 s is Apple's
    /// recommended ceiling for "interactive" HTTPS in their
    /// `URLSessionConfiguration` reference — long enough for
    /// slow TLS handshakes in cellular environments, short
    /// enough that wedged peers don't wedge the caller.
    public static let defaultTimeout: Duration = .seconds(30)

    private let session: URLSession
    private let defaultSigner: (any RequestSigner)?
    private let defaultTimeout: Duration
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        session: URLSession = .shared,
        defaultSigner: (any RequestSigner)? = nil,
        defaultTimeout: Duration = URLSessionHTTPSClient.defaultTimeout,
        encoder: JSONEncoder = URLSessionHTTPSClient.makeDefaultEncoder(),
        decoder: JSONDecoder = URLSessionHTTPSClient.makeDefaultDecoder()
    ) {
        self.session = session
        self.defaultSigner = defaultSigner
        self.defaultTimeout = defaultTimeout
        self.encoder = encoder
        self.decoder = decoder
    }

    public func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ request: HTTPSRequest<Request>,
        decoding: Response.Type
    ) async throws -> Response {
        let data = try await performRequest(request)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw HTTPSError.decode(underlying: error)
        }
    }

    public func send<Response: Decodable & Sendable>(
        _ request: HTTPSRequest<EmptyBody>,
        decoding: Response.Type
    ) async throws -> Response {
        let data = try await performRequest(request)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw HTTPSError.decode(underlying: error)
        }
    }

    public func send<Request: Encodable & Sendable>(
        _ request: HTTPSRequest<Request>
    ) async throws {
        _ = try await performRequest(request)
    }

    public func sendRaw<Request: Encodable & Sendable>(
        _ request: HTTPSRequest<Request>
    ) async throws -> (data: Data, headers: [String: String]) {
        try await performRequestWithHeaders(request)
    }

    // MARK: - Private

    private func performRequest<Body: Encodable & Sendable>(
        _ request: HTTPSRequest<Body>
    ) async throws -> Data {
        try await performRequestWithHeaders(request).data
    }

    private func performRequestWithHeaders<Body: Encodable & Sendable>(
        _ request: HTTPSRequest<Body>
    ) async throws -> (data: Data, headers: [String: String]) {
        var urlRequest = URLRequest(
            url: request.url,
            timeoutInterval: TimeInterval(
                (request.timeout ?? defaultTimeout).components.seconds
            )
        )
        urlRequest.httpMethod = request.method.rawValue
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        if let body = request.body, !(body is EmptyBody) {
            do {
                urlRequest.httpBody = try encoder.encode(body)
                if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                    urlRequest.setValue(
                        "application/json",
                        forHTTPHeaderField: "Content-Type"
                    )
                }
            } catch {
                throw HTTPSError.encode(underlying: error)
            }
        }

        let signer = request.signer ?? defaultSigner
        if let signer {
            do {
                try await signer.sign(&urlRequest)
            } catch {
                throw HTTPSError.signing(underlying: error)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw HTTPSError.transport(underlying: error)
        }

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw HTTPSError.status(code: http.statusCode, body: data)
        }

        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                if let keyString = key as? String, let valueString = value as? String {
                    headers[keyString] = valueString
                }
            }
        }
        return (data, headers)
    }

    public static func makeDefaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDefaultDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

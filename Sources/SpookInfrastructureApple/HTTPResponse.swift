import Foundation
import SpookCore
import SpookApplication

// MARK: - JSON Envelope

/// A typed JSON envelope for all API responses.
///
/// Every response follows the pattern:
/// ```json
/// {"status": "ok", "data": { ... }}
/// {"error": {"code": "...", "message": "...", "requestId": "..."}}
/// ```
///
/// Using generics with `Codable` eliminates all `[String: Any]`
/// and `JSONSerialization` usage, giving compile-time type safety
/// and deterministic JSON key ordering.
struct APIEnvelope<T: Encodable>: Encodable {
    let status: String
    let data: T?
    let error: StandardErrorEnvelope?

    init(data: T) {
        self.status = "ok"
        self.data = data
        self.error = nil
    }

    init(error: StandardErrorEnvelope) where T == EmptyData {
        self.status = "error"
        self.data = nil
        self.error = error
    }
}

/// Placeholder for error envelopes that carry no data payload.
struct EmptyData: Encodable {}

/// Stable machine-readable error codes for the HTTP API.
///
/// Clients switch on `StandardErrorCode.rawValue` rather than the
/// human-readable `message` — the former is a contract, the latter
/// a diagnostic aid that can change between releases.
enum StandardErrorCode: String, Sendable {
    case malformedRequest = "malformed_request"
    case unauthorized = "unauthorized"
    case forbidden = "forbidden"
    case notFound = "not_found"
    case conflict = "conflict"
    case payloadTooLarge = "payload_too_large"
    case unprocessable = "unprocessable"
    case rateLimited = "rate_limited"
    case timeout = "request_timeout"
    case methodNotAllowed = "method_not_allowed"
    case serviceUnavailable = "service_unavailable"
    case internalError = "internal_error"
}

/// The error body for every failed HTTP response.
///
/// ```json
/// {"error": {"code": "unauthorized", "message": "...", "requestId": "..."}}
/// ```
struct StandardErrorEnvelope: Encodable, Sendable {
    let code: String
    let message: String
    let requestId: String
}

// MARK: - HTTP Response

/// An HTTP response with status code, headers, and body.
///
/// Serializes to a complete HTTP/1.1 response including the status
/// line, headers (`Content-Type`, `Content-Length`,
/// `Connection: close`), and body. The body is JSON by default but
/// can be plain text when using ``plainText(_:statusCode:contentType:)``.
struct HTTPResponse: Sendable {

    /// The HTTP status code (e.g., 200, 404, 500).
    let statusCode: Int

    /// The response body as raw bytes.
    let body: Data

    /// The value for the `Content-Type` header.
    let contentType: String

    /// Per-request correlation identifier. Emitted as `X-Request-ID`
    /// on every serialized response so operators can correlate
    /// server logs with client-visible failures.
    let requestID: String

    /// Shared encoder with sorted keys for deterministic output.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// The HTTP status text for common status codes.
    private var statusText: String {
        switch statusCode {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 422: "Unprocessable Entity"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }

    /// Serializes the response to raw HTTP/1.1 bytes with a
    /// default set of security headers per OWASP ASVS V14.4.
    ///
    /// The default set is conservative for a JSON-only control-
    /// plane API — no scripts, no frames, no caching of sensitive
    /// bodies, no referrer leakage. Operators who front the API
    /// with an HTML UI or embed responses into a browser would
    /// need to relax Content-Security-Policy and Cache-Control;
    /// this server doesn't serve HTML so the strictest defaults
    /// apply.
    func serialize() -> Data {
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"

        // OWASP ASVS V14.4.1 — Content-Type must carry a charset.
        // The Content-Type values we emit already include the
        // charset suffix (see HTTPResponse.ok / .error), so the
        // separate assertion is implicit.

        // ASVS V14.4.2 — API responses contain `X-Content-Type-Options: nosniff`.
        // Prevents MIME-sniffing attacks where a browser
        // re-interprets a JSON response as HTML / JavaScript.
        response += "X-Content-Type-Options: nosniff\r\n"

        // ASVS V14.4.3 — content-security-policy header.
        // `default-src 'none'` for a JSON API means the browser
        // should run no scripts, fetch no resources, render no
        // frames based on this response. Correct posture for an
        // API that never legitimately serves HTML/JS.
        response += "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n"

        // ASVS V14.4.7 — `X-Frame-Options: DENY` (legacy but
        // still enforced by some older browsers that ignore the
        // CSP `frame-ancestors` directive above). Defense in
        // depth against clickjacking of responses served into
        // an iframe.
        response += "X-Frame-Options: DENY\r\n"

        // ASVS V14.4.5 — HSTS on TLS-only deployments. Informs
        // any browser that stumbles into this endpoint over HTTP
        // to upgrade. Harmless on plain-HTTP dev servers (the
        // browser simply ignores it absent a prior HTTPS
        // connection). One-year max-age matches the HSTS
        // preload-list requirement.
        response += "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n"

        // ASVS V14.4.6 — Referrer-Policy. `no-referrer` ensures
        // a response served into a browser tab doesn't leak the
        // internal API URL to third-party destinations when the
        // user subsequently clicks a link in rendered content.
        response += "Referrer-Policy: no-referrer\r\n"

        // Control-plane responses often carry sensitive tenant
        // and identity data; an intermediary cache returning a
        // stale response to the wrong caller is the failure mode
        // `no-store` prevents. Not strictly an ASVS requirement,
        // but obviously correct for a per-caller API.
        response += "Cache-Control: no-store\r\n"

        // X-Request-ID — every response carries its correlation
        // ID so operators can pivot from a client report
        // ("I got a 500") to the server log line that recorded
        // the underlying failure.
        response += "X-Request-ID: \(requestID)\r\n"

        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    /// Creates a success response with a typed JSON data payload.
    static func ok<T: Encodable>(
        _ data: T,
        statusCode: Int = 200,
        requestID: String = UUID().uuidString
    ) -> HTTPResponse {
        let envelope = APIEnvelope(data: data)
        let body = (try? encoder.encode(envelope)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            body: body,
            contentType: "application/json; charset=utf-8",
            requestID: requestID
        )
    }

    /// Creates an error response with a standard error envelope.
    ///
    /// ```json
    /// {"error": {"code": "unauthorized", "message": "...", "requestId": "..."}}
    /// ```
    ///
    /// - Parameters:
    ///   - code: The stable machine-readable error code.
    ///   - message: A short human-readable description; MUST NOT
    ///     embed sensitive internals (filesystem paths, Keychain
    ///     error strings, stack traces).
    ///   - statusCode: The HTTP status code to emit.
    ///   - requestID: The per-request correlation ID.
    static func error(
        code: StandardErrorCode,
        message: String,
        statusCode: Int,
        requestID: String = UUID().uuidString
    ) -> HTTPResponse {
        let envelope = APIEnvelope<EmptyData>(error: StandardErrorEnvelope(
            code: code.rawValue,
            message: message,
            requestId: requestID
        ))
        let body = (try? Self.encoder.encode(envelope)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            body: body,
            contentType: "application/json; charset=utf-8",
            requestID: requestID
        )
    }

    /// Legacy error helper — picks a code from the status code so
    /// older call sites continue to emit a valid envelope without
    /// every caller being re-written at once. New code should call
    /// ``error(code:message:statusCode:requestID:)`` with an
    /// explicit ``StandardErrorCode``.
    static func error(
        message: String,
        statusCode: Int,
        requestID: String = UUID().uuidString
    ) -> HTTPResponse {
        let code = defaultCode(for: statusCode)
        return error(code: code, message: message, statusCode: statusCode, requestID: requestID)
    }

    /// Maps common HTTP status codes to default ``StandardErrorCode``
    /// values. Used by the legacy ``error(message:statusCode:)``
    /// helper so pre-envelope call sites still produce conformant
    /// bodies.
    static func defaultCode(for statusCode: Int) -> StandardErrorCode {
        switch statusCode {
        case 400: return .malformedRequest
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 405: return .methodNotAllowed
        case 408: return .timeout
        case 409: return .conflict
        case 413: return .payloadTooLarge
        case 422: return .unprocessable
        case 429: return .rateLimited
        case 503: return .serviceUnavailable
        default: return .internalError
        }
    }

    /// Creates a sanitized 500 Internal Server Error response.
    ///
    /// The body carries a stable `"Internal error. Correlation ID:
    /// <uuid>."` message. The underlying error is neither encoded
    /// nor rendered into the response body — use `Log.httpAPI.error`
    /// at the call site with the same correlation ID so operators
    /// can pivot from the HTTP response to the server logs without
    /// leaking stack details, filesystem paths, Keychain codes, or
    /// `SecItem` error strings to the caller.
    ///
    /// Callers get back the correlation ID so they can log it
    /// alongside the underlying error:
    ///
    /// ```swift
    /// let (response, correlationID) = HTTPResponse.internalError()
    /// logger.error("handleFoo failed [\(correlationID, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
    /// return response
    /// ```
    static func internalError(requestID: String = UUID().uuidString) -> (response: HTTPResponse, correlationID: String) {
        let msg = "Internal error. Correlation ID: \(requestID). Consult server logs."
        return (
            HTTPResponse.error(code: .internalError, message: msg, statusCode: 500, requestID: requestID),
            requestID
        )
    }

    /// Creates a plain-text response with a custom content type.
    ///
    /// - Parameters:
    ///   - text: The plain-text body.
    ///   - statusCode: The HTTP status code. Defaults to `200`.
    ///   - contentType: The `Content-Type` header value. Defaults to
    ///     `"text/plain; charset=utf-8"`.
    ///   - requestID: The per-request correlation ID.
    /// - Returns: An ``HTTPResponse`` with the given text body.
    static func plainText(
        _ text: String,
        statusCode: Int = 200,
        contentType: String = "text/plain; charset=utf-8",
        requestID: String = UUID().uuidString
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            body: Data(text.utf8),
            contentType: contentType,
            requestID: requestID
        )
    }

    /// Returns a copy of this response with the given request ID.
    ///
    /// The server pipeline creates responses inside per-route
    /// handlers that don't always plumb the request's ID (which
    /// would force a rewrite of every signature). The outer
    /// dispatcher stamps the canonical ID on the way back out —
    /// the serialized wire form and the embedded error envelope
    /// both reflect the same ID that lands in server logs.
    func with(requestID: String) -> HTTPResponse {
        // Rewrite error envelopes so the body's requestId field
        // matches the header. Success bodies don't encode an ID,
        // so the simple replacement is byte-identical.
        let newBody: Data
        if contentType.hasPrefix("application/json"),
           let original = try? Self.envelopeDecoder.decode(RewritableErrorEnvelope.self, from: body),
           let err = original.error {
            let rewritten = APIEnvelope<EmptyData>(error: StandardErrorEnvelope(
                code: err.code, message: err.message, requestId: requestID
            ))
            newBody = (try? Self.encoder.encode(rewritten)) ?? body
        } else {
            newBody = body
        }
        return HTTPResponse(
            statusCode: statusCode,
            body: newBody,
            contentType: contentType,
            requestID: requestID
        )
    }

    /// Private decoder used only by ``with(requestID:)`` to detect
    /// error envelopes that need their `requestId` rewritten.
    private static let envelopeDecoder = JSONDecoder()

    /// Decode-side mirror of ``APIEnvelope`` used only by
    /// ``with(requestID:)``. Kept private so no external code can
    /// take a dependency on the transitional shape.
    private struct RewritableErrorEnvelope: Decodable {
        let error: StandardErrorEnvelope?
    }
}

// MARK: - StandardErrorEnvelope Codable

extension StandardErrorEnvelope: Decodable {}

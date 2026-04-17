import Foundation
import SpookCore
import SpookApplication

// MARK: - JSON Envelope

/// A typed JSON envelope for all API responses.
///
/// Every response follows the pattern:
/// ```json
/// {"status": "ok", "data": { ... }}
/// {"status": "error", "message": "..."}
/// ```
///
/// Using generics with `Codable` eliminates all `[String: Any]`
/// and `JSONSerialization` usage, giving compile-time type safety
/// and deterministic JSON key ordering.
struct APIEnvelope<T: Encodable>: Encodable {
    let status: String
    let data: T?
    let message: String?

    init(data: T) {
        self.status = "ok"
        self.data = data
        self.message = nil
    }

    init(error message: String) where T == EmptyData {
        self.status = "error"
        self.data = nil
        self.message = message
    }
}

/// Placeholder for error envelopes that carry no data payload.
struct EmptyData: Encodable {}

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
        case 404: "Not Found"
        case 409: "Conflict"
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

        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    /// Creates a success response with a typed JSON data payload.
    static func ok<T: Encodable>(_ data: T, statusCode: Int = 200) -> HTTPResponse {
        let envelope = APIEnvelope(data: data)
        let body = (try? encoder.encode(envelope)) ?? Data("{}".utf8)
        return HTTPResponse(statusCode: statusCode, body: body, contentType: "application/json; charset=utf-8")
    }

    /// Creates an error response with a JSON message.
    static func error(message: String, statusCode: Int) -> HTTPResponse {
        let envelope = APIEnvelope<EmptyData>(error: message)
        let body = (try? Self.encoder.encode(envelope)) ?? Data("{}".utf8)
        return HTTPResponse(statusCode: statusCode, body: body, contentType: "application/json; charset=utf-8")
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
    static func internalError() -> (response: HTTPResponse, correlationID: String) {
        let id = UUID().uuidString
        let msg = "Internal error. Correlation ID: \(id). Consult server logs."
        return (HTTPResponse.error(message: msg, statusCode: 500), id)
    }

    /// Creates a plain-text response with a custom content type.
    ///
    /// - Parameters:
    ///   - text: The plain-text body.
    ///   - statusCode: The HTTP status code. Defaults to `200`.
    ///   - contentType: The `Content-Type` header value. Defaults to
    ///     `"text/plain; charset=utf-8"`.
    /// - Returns: An ``HTTPResponse`` with the given text body.
    static func plainText(
        _ text: String,
        statusCode: Int = 200,
        contentType: String = "text/plain; charset=utf-8"
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            body: Data(text.utf8),
            contentType: contentType
        )
    }
}

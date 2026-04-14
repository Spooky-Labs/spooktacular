import Foundation

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

/// An HTTP response with status code, headers, and JSON body.
///
/// Serializes to a complete HTTP/1.1 response including the status
/// line, headers (`Content-Type`, `Content-Length`,
/// `Connection: close`), and body. The body is always JSON.
struct HTTPResponse: Sendable {

    /// The HTTP status code (e.g., 200, 404, 500).
    let statusCode: Int

    /// The JSON response body as raw bytes.
    let body: Data

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
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }

    /// Serializes the response to raw HTTP/1.1 bytes.
    func serialize() -> Data {
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: application/json; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    /// Creates a success response with a typed data payload.
    static func ok<T: Encodable>(_ data: T, statusCode: Int = 200) -> HTTPResponse {
        let envelope = APIEnvelope(data: data)
        let body = (try? encoder.encode(envelope)) ?? Data("{}".utf8)
        return HTTPResponse(statusCode: statusCode, body: body)
    }

    /// Creates an error response with a message.
    static func error(message: String, statusCode: Int) -> HTTPResponse {
        let envelope = APIEnvelope<EmptyData>(error: message)
        let body = (try? Self.encoder.encode(envelope)) ?? Data("{}".utf8)
        return HTTPResponse(statusCode: statusCode, body: body)
    }
}

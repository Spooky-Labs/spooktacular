import Foundation
import SpookCore
import SpookApplication

// MARK: - HTTP Request

/// A parsed HTTP/1.1 request.
///
/// Contains the essential parts of an HTTP request: the method,
/// path, headers, and optional body. Only the headers needed for
/// API routing and framing (`Content-Length`, `Content-Type`,
/// `Authorization`) are exposed by name; all headers are preserved.
struct HTTPRequest: Sendable {

    /// The HTTP method (e.g., `"GET"`, `"POST"`, `"DELETE"`).
    let method: String

    /// The request path, query string stripped (e.g., `"/v1/vms"`).
    let path: String

    /// Parsed HTTP headers as key-value pairs. Keys are lowercased.
    let headers: [String: String]

    /// The request body, if present. Raw bytes — may be binary.
    let body: Data?
}

// MARK: - HTTP Request Parser

/// A minimal HTTP/1.1 request parser.
///
/// Parses the request line, headers, and body from raw TCP bytes.
/// Supports the subset of HTTP needed for Spooktacular's API:
///
/// - Request line: `METHOD /path HTTP/1.1`
/// - Headers separated by `\r\n`, terminated by `\r\n\r\n`
/// - Body length driven by `Content-Length`
///
/// Chunked transfer encoding, pipelining, HTTP/2, and keep-alive
/// are intentionally unsupported — connections are one request and
/// one response.
enum HTTPRequestParser {

    /// Marker sequence terminating the header block.
    private static let headerTerminator = Data([0x0d, 0x0a, 0x0d, 0x0a])   // \r\n\r\n

    /// Single CRLF — separates request line and individual headers.
    private static let crlf = Data([0x0d, 0x0a])                           // \r\n

    /// Attempts to parse a complete HTTP request from the given buffer.
    ///
    /// - Returns: The parsed request if the buffer contains a complete
    ///   request (headers + exact `Content-Length` body). Returns `nil`
    ///   if more bytes are needed.
    /// - Throws: ``HTTPAPIServerError/malformedRequest`` if the headers
    ///   cannot be parsed or advertise an invalid `Content-Length`.
    static func parseIfComplete(_ buffer: Data) throws -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: headerTerminator) else {
            return nil
        }

        let headerBlock = buffer[..<headerEnd.lowerBound]
        let bodyStart = headerEnd.upperBound

        let headerString = String(data: headerBlock, encoding: .utf8) ?? ""
        guard !headerString.isEmpty else {
            throw HTTPAPIServerError.malformedRequest
        }

        var lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPAPIServerError.malformedRequest
        }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            throw HTTPAPIServerError.malformedRequest
        }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = String(rawPath.prefix(while: { $0 != "?" }))

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Determine expected body length. Absent Content-Length ⇒ no body.
        let contentLength: Int
        if let value = headers["content-length"] {
            guard let parsed = Int(value), parsed >= 0 else {
                throw HTTPAPIServerError.malformedRequest
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        let bytesAvailable = buffer.count - bodyStart
        guard bytesAvailable >= contentLength else {
            return nil   // more body bytes still incoming
        }

        let body: Data?
        if contentLength > 0 {
            body = buffer[bodyStart..<(bodyStart + contentLength)]
        } else {
            body = nil
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

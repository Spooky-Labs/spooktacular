import Foundation

// MARK: - HTTP Request

/// A parsed HTTP request.
///
/// Contains the essential parts of an HTTP/1.1 request: the method,
/// path, headers, and optional body. Only the headers needed for
/// API routing (`Content-Length`, `Content-Type`) are parsed.
struct HTTPRequest: Sendable {

    /// The HTTP method (e.g., `"GET"`, `"POST"`, `"DELETE"`).
    let method: String

    /// The request path (e.g., `"/v1/vms"`).
    let path: String

    /// Parsed HTTP headers as key-value pairs. Keys are lowercased.
    let headers: [String: String]

    /// The request body, if present.
    let body: Data?
}

// MARK: - HTTP Request Parser

/// A minimal HTTP/1.1 request parser.
///
/// Parses the request line, headers, and body from raw TCP data.
/// This parser handles the subset of HTTP needed for the API:
/// - Request line: `METHOD /path HTTP/1.1`
/// - Headers: `Content-Length` and `Content-Type`
/// - Body: read based on `Content-Length`
///
/// It does not support chunked transfer encoding, HTTP/2,
/// keep-alive, or any advanced HTTP features.
enum HTTPRequestParser {

    /// Parses raw TCP data into an ``HTTPRequest``.
    ///
    /// - Parameter data: The raw bytes received from the TCP connection.
    /// - Returns: A parsed HTTP request.
    /// - Throws: ``HTTPAPIServerError/malformedRequest`` if the data
    ///   cannot be parsed as a valid HTTP request.
    static func parse(_ data: Data) throws -> HTTPRequest {
        guard let string = String(data: data, encoding: .utf8) else {
            throw HTTPAPIServerError.malformedRequest
        }

        let parts = string.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else {
            throw HTTPAPIServerError.malformedRequest
        }

        var lines = headerSection.components(separatedBy: "\r\n")

        guard let requestLine = lines.first else {
            throw HTTPAPIServerError.malformedRequest
        }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else {
            throw HTTPAPIServerError.malformedRequest
        }

        let method = String(requestParts[0])
        let rawPath = String(requestParts[1])
        let path = String(rawPath.prefix(while: { $0 != "?" }))

        var headers: [String: String] = [:]
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        var body: Data?
        if parts.count > 1 {
            let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: body
        )
    }
}

/// A minimal, standalone HTTP/1.1 request parser for spooktacular-agent.
///
/// Parses the request line, headers, query parameters, and body from
/// raw TCP data. This parser supports the subset of HTTP needed by
/// the agent's REST API:
///
/// - Request line: `METHOD /path?key=value HTTP/1.1`
/// - Headers: key-value pairs (keys lowercased)
/// - Body: read based on `Content-Length`
///
/// It does **not** support chunked transfer encoding, HTTP/2,
/// keep-alive, or multipart requests.

import Foundation

// MARK: - Parsed Request

/// A parsed HTTP request with method, path, query parameters, headers, and body.
struct AgentHTTPRequest: Sendable {
    /// The HTTP method (`"GET"`, `"POST"`, etc.).
    let method: String
    /// The request path without query string (e.g., `"/api/v1/fs"`).
    let path: String
    /// Parsed query parameters (e.g., `["path": "/foo"]`).
    let query: [String: String]
    /// HTTP headers with lowercased keys.
    let headers: [String: String]
    /// The request body, if present.
    let body: Data?
}

// MARK: - Parser

/// A stateless HTTP/1.1 request parser.
///
/// All functionality is exposed through the ``parse(_:)`` static method.
/// The parser is intentionally simple -- it handles exactly what the
/// agent API needs and nothing more.
enum AgentHTTPParser {

    /// Errors that can occur during HTTP parsing.
    enum ParseError: Error {
        /// The raw data is not valid UTF-8.
        case invalidEncoding
        /// The request line is missing or malformed.
        case malformedRequestLine
    }

    /// Parses raw TCP data into an ``AgentHTTPRequest``.
    ///
    /// The parser splits the data on the `\r\n\r\n` header/body boundary,
    /// extracts the request line and headers, then reads the body using
    /// the `Content-Length` header if present.
    ///
    /// - Parameter data: Raw bytes received from the socket.
    /// - Returns: A fully parsed ``AgentHTTPRequest``.
    /// - Throws: ``ParseError`` if the data cannot be parsed.
    static func parse(_ data: Data) throws -> AgentHTTPRequest {
        guard let string = String(data: data, encoding: .utf8) else {
            throw ParseError.invalidEncoding
        }

        let parts = string.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else {
            throw ParseError.malformedRequestLine
        }

        var lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ParseError.malformedRequestLine
        }
        lines.removeFirst()

        // Parse request line: "METHOD /path?query HTTP/1.1"
        let tokens = requestLine.split(separator: " ", maxSplits: 2)
        guard tokens.count >= 2 else {
            throw ParseError.malformedRequestLine
        }

        let method = String(tokens[0])
        let rawURI = String(tokens[1])

        // Split path and query string
        let path: String
        var query: [String: String] = [:]

        if let questionMark = rawURI.firstIndex(of: "?") {
            path = String(rawURI[rawURI.startIndex..<questionMark])
            let queryString = String(rawURI[rawURI.index(after: questionMark)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let key = kv.first else { continue }
                let value = kv.count > 1 ? String(kv[1]) : ""
                query[String(key)] = value.removingPercentEncoding ?? value
            }
        } else {
            path = rawURI
        }

        // Parse headers
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

        // Extract body
        var body: Data?
        if parts.count > 1 {
            let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
            }
        }

        return AgentHTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }
}

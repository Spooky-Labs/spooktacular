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
        /// A header line could not be parsed.
        case malformedHeader
        /// Two or more `Content-Length` headers were present.
        case duplicateContentLength
        /// The request-line method or path contained non-ASCII bytes.
        case nonASCIIMethodOrPath
        /// A header used a non-CRLF line terminator.
        case nonCRLFLineEndings
    }

    /// Marker sequence terminating the header block.
    private static let crlfCRLF = Data([0x0d, 0x0a, 0x0d, 0x0a])

    /// Parses raw TCP data into an ``AgentHTTPRequest``.
    ///
    /// Strict HTTP/1.1 parsing:
    /// - `\r\n\r\n` header/body separator only (a bare `\n\n` is rejected).
    /// - Request line and headers must be ASCII (RFC 7230 §3).
    /// - Duplicate `Content-Length` → `duplicateContentLength` error.
    /// - Header values are trimmed of leading/trailing whitespace.
    ///
    /// - Parameter data: Raw bytes received from the socket.
    /// - Returns: A fully parsed ``AgentHTTPRequest``.
    /// - Throws: ``ParseError`` if the data cannot be parsed.
    static func parse(_ data: Data) throws -> AgentHTTPRequest {
        // Require CRLF framing on the byte level BEFORE converting
        // to a String; `String.components(separatedBy:)` is lenient
        // about line endings and would quietly accept LF-only input.
        guard data.range(of: crlfCRLF) != nil else {
            throw ParseError.nonCRLFLineEndings
        }

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

        // RFC 7230 §3.1.1 restricts the request-line to ASCII. Non-
        // ASCII bytes in the method or URI should be %-encoded at
        // the client; we reject rather than interpret.
        guard method.allSatisfy({ $0.isASCII }), rawURI.allSatisfy({ $0.isASCII }) else {
            throw ParseError.nonASCIIMethodOrPath
        }

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

        // Parse headers — strict mode.
        // - Every header line MUST have a colon.
        // - Values are trimmed of leading/trailing whitespace
        //   (including tabs) per RFC 7230 §3.2.4.
        // - Duplicate `Content-Length` is a framing-smuggling
        //   precursor and must be rejected.
        var headers: [String: String] = [:]
        var contentLengthSeen = false
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw ParseError.malformedHeader
            }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)

            if key == "content-length" {
                guard !contentLengthSeen else {
                    throw ParseError.duplicateContentLength
                }
                contentLengthSeen = true
            }

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

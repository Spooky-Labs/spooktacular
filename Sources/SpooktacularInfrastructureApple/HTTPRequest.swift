import Foundation
import SpooktacularCore
import SpooktacularApplication

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

    /// An opaque per-request correlation identifier. Surfaces in the
    /// `X-Request-ID` response header and in the standard error
    /// envelope so operators can pivot from a client-visible
    /// response to a server log line without leaking internals.
    let requestID: String
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

    /// Outcome of parsing a partial buffer against a byte cap.
    ///
    /// The cap is enforced *before* trusting `Content-Length`: an
    /// attacker who advertises `Content-Length: 9999999999` must be
    /// rejected immediately with `.tooLarge`, never given a chance
    /// to fill a multi-gigabyte buffer.
    enum ParseResult: Sendable {
        /// The buffer contains a complete, well-formed request.
        case complete(HTTPRequest)
        /// More bytes are still needed.
        case needMore
        /// The advertised or actual body exceeds `maxRequestBytes`.
        case tooLarge
    }

    /// Attempts to parse a complete HTTP request from the given
    /// buffer against a hard byte cap.
    ///
    /// - Parameters:
    ///   - buffer: Accumulated bytes from a single connection.
    ///   - maxRequestBytes: Total header + body ceiling. If the
    ///     `Content-Length` header advertises a body larger than
    ///     `maxRequestBytes - headerSize`, `.tooLarge` is returned
    ///     without buffering another byte.
    /// - Returns: ``ParseResult`` — complete, need-more, or
    ///   too-large.
    /// - Throws: ``HTTPAPIServerError/malformedRequest`` on any
    ///   framing defect (duplicate `Content-Length`, unparseable
    ///   request line, invalid `Content-Length` value).
    static func parseIfComplete(_ buffer: Data, maxRequestBytes: Int) throws -> ParseResult {
        guard let headerEnd = buffer.range(of: headerTerminator) else {
            return .needMore
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

        // Parse headers with strict HTTP/1.1 checks:
        // - Reject duplicate `Content-Length` (CVE-class request
        //   smuggling precursor).
        // - Reject non-ASCII bytes in method / path (callers should
        //   `%`-encode before dispatching).
        // - Reject header lines lacking a colon that also contain
        //   non-whitespace content (folded headers are unsupported).
        var headers: [String: String] = [:]
        var contentLengthSeen = false
        for line in lines {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else {
                // A header line without `:` is a framing defect.
                // Folded / obs-fold headers are obsolete under
                // RFC 7230 §3.2.4 and we reject rather than merge.
                throw HTTPAPIServerError.malformedRequest
            }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)

            if key == "content-length" {
                guard !contentLengthSeen else {
                    // Two `Content-Length` headers is the classic
                    // request-smuggling vector. RFC 7230 §3.3.2
                    // says "MUST reject as 400".
                    throw HTTPAPIServerError.duplicateContentLength
                }
                contentLengthSeen = true
            }

            headers[key] = value
        }

        // ASCII-only method/path. RFC 7230 §3.1.1 limits the request
        // line to a token + request-target; non-ASCII is a bug at
        // best and a smuggling primitive at worst.
        guard method.allSatisfy({ $0.isASCII }), path.allSatisfy({ $0.isASCII }) else {
            throw HTTPAPIServerError.malformedRequest
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

        // P0: reject oversized bodies BEFORE attempting to buffer.
        // `headerEnd.upperBound` is the byte offset where the body
        // starts; any `Content-Length` that would push total bytes
        // past `maxRequestBytes` is refused on the spot.
        if bodyStart + contentLength > maxRequestBytes {
            return .tooLarge
        }

        let bytesAvailable = buffer.count - bodyStart
        guard bytesAvailable >= contentLength else {
            return .needMore
        }

        let body: Data?
        if contentLength > 0 {
            body = buffer[bodyStart..<(bodyStart + contentLength)]
        } else {
            body = nil
        }

        // Honor an inbound X-Request-ID if the client supplied one
        // (length capped at 128 chars to prevent log injection);
        // otherwise mint one.
        let incomingID = headers["x-request-id"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard (1...128).contains(trimmed.count),
                  trimmed.allSatisfy({ $0.isASCII && !$0.isNewline })
            else { return nil }
            return trimmed
        }
        let requestID = incomingID ?? UUID().uuidString

        return .complete(HTTPRequest(
            method: method, path: path, headers: headers,
            body: body, requestID: requestID
        ))
    }
}

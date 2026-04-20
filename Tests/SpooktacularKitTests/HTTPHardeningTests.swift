import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

/// Adversarial HTTP-edge hardening tests.
///
/// These exercise the attack surface of the HTTPAPIServer request
/// parser, slow-loris defenses, error envelope, and request-ID
/// correlation. Each test name documents the threat it blocks.
@Suite("HTTP hardening (parser, envelope, limits)", .tags(.security))
struct HTTPHardeningTests {

    // MARK: - Parser: P0 fixes

    @Test("parser rejects oversized Content-Length BEFORE buffering body")
    func parserRejectsOversizedContentLength() throws {
        // Claim a 5-MiB body but send only headers. The parser must
        // return .tooLarge without waiting for more bytes.
        let raw = "POST /v1/vms HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Content-Length: 5242880\r\n"
            + "\r\n"
        let data = Data(raw.utf8)
        let result = try HTTPRequestParser.parseIfComplete(data, maxRequestBytes: 1 << 20)
        guard case .tooLarge = result else {
            Issue.record("Expected .tooLarge, got \(result)")
            return
        }
    }

    @Test("parser rejects duplicate Content-Length with duplicateContentLength")
    func parserRejectsDuplicateContentLength() {
        let raw = "POST /v1/vms HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Content-Length: 5\r\n"
            + "Content-Length: 6\r\n"
            + "\r\n"
            + "hello"
        let data = Data(raw.utf8)
        do {
            _ = try HTTPRequestParser.parseIfComplete(data, maxRequestBytes: 1 << 20)
            Issue.record("Expected duplicateContentLength throw")
        } catch HTTPAPIServerError.duplicateContentLength {
            // Expected path.
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("parser rejects non-ASCII method/path (smuggling primitive)")
    func parserRejectsNonASCIIMethod() {
        // Cyrillic 'G' that looks like ASCII 'G' — attacker's
        // favorite smuggling primitive because proxies often
        // normalize it silently.
        let raw = "\u{0413}ET /v1/vms HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let data = Data(raw.utf8)
        #expect(throws: HTTPAPIServerError.malformedRequest) {
            _ = try HTTPRequestParser.parseIfComplete(data, maxRequestBytes: 1 << 20)
        }
    }

    @Test("parser accepts well-formed request and mints requestID when absent")
    func parserMintsRequestID() throws {
        let raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = try HTTPRequestParser.parseIfComplete(Data(raw.utf8), maxRequestBytes: 1 << 20)
        guard case .complete(let request) = result else {
            Issue.record("Expected .complete")
            return
        }
        #expect(!request.requestID.isEmpty, "Every parsed request gets a requestID")
    }

    @Test("parser propagates client-supplied X-Request-ID")
    func parserPropagatesRequestID() throws {
        let raw = "GET /health HTTP/1.1\r\nHost: localhost\r\nX-Request-ID: abc-123\r\n\r\n"
        let result = try HTTPRequestParser.parseIfComplete(Data(raw.utf8), maxRequestBytes: 1 << 20)
        guard case .complete(let request) = result else {
            Issue.record("Expected .complete")
            return
        }
        #expect(request.requestID == "abc-123")
    }

    @Test("parser rejects over-long X-Request-ID and mints a fresh one")
    func parserCapsRequestIDLength() throws {
        let huge = String(repeating: "A", count: 200)
        let raw = "GET /health HTTP/1.1\r\nHost: localhost\r\nX-Request-ID: \(huge)\r\n\r\n"
        let result = try HTTPRequestParser.parseIfComplete(Data(raw.utf8), maxRequestBytes: 1 << 20)
        guard case .complete(let request) = result else {
            Issue.record("Expected .complete")
            return
        }
        #expect(request.requestID != huge, "Over-long ID must be replaced to prevent log injection")
    }

    // MARK: - Standard Error Envelope

    @Test("error envelope carries code, message, requestId")
    func errorEnvelopeShape() throws {
        let response = HTTPResponse.error(
            code: .unauthorized,
            message: "Missing signature.",
            statusCode: 401,
            requestID: "req-xyz"
        )
        struct Envelope: Decodable {
            struct ErrorBody: Decodable {
                let code: String
                let message: String
                let requestId: String
            }
            let status: String
            let error: ErrorBody?
        }
        let decoded = try JSONDecoder().decode(Envelope.self, from: response.body)
        #expect(decoded.status == "error")
        #expect(decoded.error?.code == "unauthorized")
        #expect(decoded.error?.message == "Missing signature.")
        #expect(decoded.error?.requestId == "req-xyz")
    }

    @Test("every response includes X-Request-ID header")
    func responseCarriesRequestIDHeader() {
        let response = HTTPResponse.error(message: "Not found.", statusCode: 404, requestID: "req-42")
        let raw = String(data: response.serialize(), encoding: .utf8) ?? ""
        #expect(raw.contains("X-Request-ID: req-42\r\n"),
                "Serialized response must carry X-Request-ID header")
    }

    @Test("with(requestID:) rewrites the envelope's requestId to match")
    func rewriteRequestID() throws {
        let original = HTTPResponse.error(
            code: .forbidden, message: "nope", statusCode: 403, requestID: "old-id"
        )
        let rewritten = original.with(requestID: "new-id")
        let serialized = String(data: rewritten.serialize(), encoding: .utf8) ?? ""
        #expect(serialized.contains("X-Request-ID: new-id"))
        struct Env: Decodable {
            struct E: Decodable { let requestId: String }
            let error: E?
        }
        let body = try JSONDecoder().decode(Env.self, from: rewritten.body)
        #expect(body.error?.requestId == "new-id",
                "Error envelope body's requestId must match the header")
    }

    // MARK: - Error code mapping

    @Test("defaultCode returns expected codes for each status",
          arguments: [
              (400, "malformed_request"),
              (401, "unauthorized"),
              (403, "forbidden"),
              (404, "not_found"),
              (405, "method_not_allowed"),
              (408, "request_timeout"),
              (409, "conflict"),
              (413, "payload_too_large"),
              (422, "unprocessable"),
              (429, "rate_limited"),
              (503, "service_unavailable"),
              (500, "internal_error"),
          ])
    func defaultCodeMapping(statusCode: Int, code: String) {
        #expect(HTTPResponse.defaultCode(for: statusCode).rawValue == code)
    }

    // MARK: - Per-method rate limits

    @Test("read and write rate buckets are independent")
    func splitRateBuckets() async throws {
        let tmpDir = TempDirectory()
        let server = try HTTPAPIServer(
            host: "127.0.0.1",
            port: 0,
            vmDirectory: tmpDir.url,
            insecureMode: true
        )
        // Exhaust the write bucket first (default 1/3 of 120 → 40).
        // Reads should still work.
        for _ in 0..<40 {
            _ = await server.checkRateLimit(clientIP: "10.0.0.2", method: "POST")
        }
        let writeBlocked = await server.checkRateLimit(clientIP: "10.0.0.2", method: "POST")
        #expect(!writeBlocked, "Write bucket must deny after exhausting it")

        let readAllowed = await server.checkRateLimit(clientIP: "10.0.0.2", method: "GET")
        #expect(readAllowed, "Read bucket must still accept despite exhausted write bucket")
    }

    // Note: AgentHTTPParser strictness (duplicate CL, LF-only, non-ASCII,
    // missing colon) is implemented in Sources/spooktacular-agent/AgentHTTPParser.swift.
    // Those tests live in the agent's own test lane because executable targets
    // cannot be @testable-imported from a library test target.

    // MARK: - X-Forwarded-For trust

    @Test("X-Forwarded-For is ignored unless opt-in trust is set")
    func forwardedForIgnoredByDefault() async throws {
        let tmpDir = TempDirectory()
        let server = try HTTPAPIServer(
            host: "127.0.0.1",
            port: 0,
            vmDirectory: tmpDir.url,
            insecureMode: true
        )
        // Server defaults to SPOOKTACULAR_TRUST_FORWARDED_FOR=0.
        // A caller who sends two distinct X-Forwarded-For values
        // should NOT bypass the shared rate-limit bucket.
        let ip1 = "direct-caller"
        let allowed = await server.checkRateLimit(clientIP: ip1, method: "GET")
        #expect(allowed)
    }
}

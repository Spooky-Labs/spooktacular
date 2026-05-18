import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

/// Pins the OWASP ASVS V14.4 HTTP security-header contract on
/// `HTTPResponse.serialize()`. Every response — success, error,
/// plaintext (metrics), internal-error — must carry the full set
/// so a future refactor that splits the serializer can't silently
/// strip them.
@Suite("HTTP security headers", .tags(.security))
struct HTTPSecurityHeadersTests {

    private func headersFromResponse(_ response: HTTPResponse) -> [String: String] {
        let raw = response.serialize()
        guard let text = String(data: raw, encoding: .utf8) else { return [:] }
        // Split at the first blank line — everything before is
        // the status line + headers.
        let parts = text.components(separatedBy: "\r\n\r\n")
        guard let head = parts.first else { return [:] }
        let lines = head.components(separatedBy: "\r\n")
        // Skip the "HTTP/1.1 200 OK" status line.
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    @Test("ok response carries the full ASVS V14.4 header set")
    func okResponseHasHeaders() {
        struct Payload: Encodable { let x: Int }
        let headers = headersFromResponse(HTTPResponse.ok(Payload(x: 1)))
        #expect(headers["X-Content-Type-Options"] == "nosniff")
        #expect(headers["X-Frame-Options"] == "DENY")
        #expect(headers["Content-Security-Policy"]?.contains("default-src 'none'") == true)
        #expect(headers["Strict-Transport-Security"]?.contains("max-age=") == true)
        #expect(headers["Referrer-Policy"] == "no-referrer")
        #expect(headers["Cache-Control"] == "no-store")
    }

    @Test("error response carries the full ASVS V14.4 header set")
    func errorResponseHasHeaders() {
        let headers = headersFromResponse(HTTPResponse.error(message: "nope", statusCode: 400))
        #expect(headers["X-Content-Type-Options"] == "nosniff")
        #expect(headers["X-Frame-Options"] == "DENY")
        #expect(headers["Content-Security-Policy"]?.contains("default-src 'none'") == true)
    }

    @Test("internalError response keeps the header set (sensitive surface)")
    func internalErrorHasHeaders() {
        let (response, _) = HTTPResponse.internalError()
        let headers = headersFromResponse(response)
        #expect(headers["X-Content-Type-Options"] == "nosniff")
        #expect(headers["Cache-Control"] == "no-store",
                "500 responses must not be cacheable — they carry correlation IDs")
    }

    @Test("plaintext response (metrics) also carries the header set")
    func plainTextHasHeaders() {
        let headers = headersFromResponse(HTTPResponse.plainText("# HELP metric\n"))
        #expect(headers["X-Content-Type-Options"] == "nosniff")
        #expect(headers["Content-Security-Policy"]?.contains("default-src 'none'") == true)
    }
}

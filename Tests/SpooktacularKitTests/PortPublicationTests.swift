import Testing
import Foundation
@testable import SpooktacularCore

@Suite("PortPublication", .tags(.networking))
struct PortPublicationTests {

    @Test("parses host:guest form")
    func parsesPair() throws {
        let publication = try #require(PortPublication("8080:18789"))
        #expect(publication.hostPort == 8080)
        #expect(publication.guestPort == 18789)
    }

    @Test("a bare port publishes the same port on both sides")
    func parsesBare() throws {
        let publication = try #require(PortPublication("18789"))
        #expect(publication.hostPort == 18789)
        #expect(publication.guestPort == 18789)
    }

    @Test("rejects malformed input", arguments: ["", "a:b", "80:", ":80", "80:90:100", "-1:80"])
    func rejectsMalformed(text: String) {
        #expect(PortPublication(text) == nil)
    }

    @Test("rejects port zero on either side", arguments: ["0:80", "80:0", "0"])
    func rejectsZero(text: String) {
        #expect(PortPublication(text) == nil)
    }

    @Test("parse rejects duplicate host ports")
    func rejectsDuplicateHostPorts() {
        #expect(throws: PortPublicationError.duplicateHostPort(8080)) {
            try PortPublication.parse(["8080:1", "8080:2"])
        }
    }

    @Test("parse returns publications in order")
    func parseOrdered() throws {
        let parsed = try PortPublication.parse(["18789", "2222:22"])
        #expect(parsed == [
            PortPublication(hostPort: 18789, guestPort: 18789),
            PortPublication(hostPort: 2222, guestPort: 22),
        ])
    }

    @Test("round-trips through JSON")
    func codableRoundTrip() throws {
        let original = [PortPublication(hostPort: 8080, guestPort: 18789)]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([PortPublication].self, from: data) == original)
    }

    @Test("description is the canonical host:guest form")
    func describes() {
        #expect(PortPublication(hostPort: 8080, guestPort: 18789).description == "8080:18789")
    }
}

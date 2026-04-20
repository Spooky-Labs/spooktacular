import Foundation
import Testing
@testable import SpooktacularCore

/// Parser coverage for the TCP-over-vsock tunnel handshake
/// path. ``TunnelPath`` is the shared Source-of-truth parser
/// both the guest agent (``TunnelHandler``) and the host-side
/// ``PortForwarder`` delegate to — a drift between the two
/// would silently break the CONNECT handshake, so the rules
/// are pinned here.
@Suite("TunnelPath parser", .tags(.security))
struct TunnelPathParserTests {

    @Test("Parses valid tunnel paths")
    func happy() {
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/8000") == 8000)
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/1") == 1)
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/65535") == 65535)
    }

    @Test("Rejects the wrong path prefix")
    func wrongPrefix() {
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/stats") == nil)
        #expect(TunnelPath.parseGuestPort(from: "/api/v2/tunnel/8000") == nil)
        #expect(TunnelPath.parseGuestPort(from: "tunnel/8000") == nil)
        #expect(TunnelPath.parseGuestPort(from: "") == nil)
    }

    @Test("Rejects non-numeric port")
    func nonNumeric() {
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/eight") == nil)
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/8000a") == nil)
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/") == nil)
    }

    @Test("Rejects out-of-range ports")
    func outOfRange() {
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/65536") == nil)
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/99999") == nil)
        // Port 0 is the POSIX wildcard, never a real target.
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/0") == nil)
    }

    @Test("Rejects smuggled URL segments or query strings")
    func smuggling() {
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/8000/secrets") == nil)
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/8000?host=evil") == nil)
        #expect(TunnelPath.parseGuestPort(from: "/api/v1/tunnel/8000/") == nil)
    }

    @Test("path(forGuestPort:) round-trips with parseGuestPort")
    func roundTrip() {
        for port: UInt16 in [80, 443, 3000, 5432, 8080, 65535] {
            let path = TunnelPath.path(forGuestPort: port)
            #expect(TunnelPath.parseGuestPort(from: path) == port)
        }
    }
}

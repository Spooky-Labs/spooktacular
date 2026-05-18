import Foundation

/// Parser + path constants for the TCP-over-vsock tunnel
/// endpoint (`POST /api/v1/tunnel/<port>`).
///
/// Lives in ``SpooktacularCore`` — the Foundation-only domain
/// layer — so both the guest-side `TunnelHandler` (which lives
/// in the agent executable target) and the host-side
/// `PortForwarder` / unit tests can reuse the exact same
/// parsing logic without duplicating validation rules. A
/// regression in either place would then mismatch the other
/// and silently break the tunnel handshake.
public enum TunnelPath {

    /// The URL prefix the agent listens for.
    public static let prefix = "/api/v1/tunnel/"

    /// Returns the guest-localhost port requested in `path`,
    /// or `nil` when the path is malformed.
    ///
    /// Rejection rules (in order):
    ///
    /// 1. `path` must start with ``prefix``.
    /// 2. The suffix must be non-empty.
    /// 3. The suffix must not contain `/` or `?` — a
    ///    permissive parser would let a compromised client
    ///    smuggle a second URL segment or query, potentially
    ///    bypassing the exact-path match in the agent's scope
    ///    table.
    /// 4. The suffix must parse as a `UInt16` (1-65535). Zero
    ///    is the POSIX wildcard and is never a real TCP
    ///    target.
    public static func parseGuestPort(from path: String) -> UInt16? {
        guard path.hasPrefix(prefix) else { return nil }
        let tail = String(path.dropFirst(prefix.count))
        guard !tail.isEmpty, !tail.contains("/"), !tail.contains("?") else {
            return nil
        }
        guard let port = UInt16(tail), port > 0 else { return nil }
        return port
    }

    /// Builds a tunnel path for `port`. Canonical way to
    /// construct a host→guest CONNECT handshake URL so host
    /// and guest agree on the exact byte sequence.
    public static func path(forGuestPort port: UInt16) -> String {
        prefix + String(port)
    }
}

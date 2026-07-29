import Foundation

/// A host-to-guest TCP port mapping, the Spooktacular equivalent of
/// `docker run -p`.
///
/// A publication becomes a vmnet port-forwarding rule when the VM
/// starts: traffic arriving on ``hostPort`` is redirected to
/// ``guestPort`` on the VM's DHCP-reserved address. Templates
/// contribute defaults (the OpenClaw gateway publishes `18789:18789`);
/// operators add their own with `--publish`.
public struct PortPublication: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {

    /// The TCP port the host listens on.
    public let hostPort: UInt16

    /// The TCP port inside the guest that traffic is forwarded to.
    public let guestPort: UInt16

    /// Creates a publication from an explicit pair.
    ///
    /// - Parameters:
    ///   - hostPort: The port exposed on the host.
    ///   - guestPort: The port inside the guest.
    public init(hostPort: UInt16, guestPort: UInt16) {
        self.hostPort = hostPort
        self.guestPort = guestPort
    }

    /// Parses the command-line forms `"<host>:<guest>"` or `"<port>"`.
    ///
    /// The bare form publishes the same number on both sides. Returns
    /// `nil` when the text is malformed or either port is zero.
    ///
    /// - Parameter text: The user-supplied value.
    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let port = UInt16(parts[0]), port != 0 else { return nil }
            self.init(hostPort: port, guestPort: port)
        case 2:
            guard let host = UInt16(parts[0]), let guest = UInt16(parts[1]),
                  host != 0, guest != 0 else { return nil }
            self.init(hostPort: host, guestPort: guest)
        default:
            return nil
        }
    }

    /// The canonical `"<host>:<guest>"` rendering.
    public var description: String { "\(hostPort):\(guestPort)" }

    /// Parses a list of command-line values, rejecting duplicates.
    ///
    /// Two rules cannot share a host port — vmnet would have no way to
    /// decide which guest receives the traffic — so a repeat is a hard
    /// error rather than a silent last-one-wins.
    ///
    /// - Parameter values: Raw `--publish` arguments, in order.
    /// - Returns: The parsed publications, preserving input order.
    /// - Throws: ``PortPublicationError`` on malformed input, a zero
    ///   port, or a duplicated host port.
    public static func parse(_ values: [String]) throws -> [PortPublication] {
        var result: [PortPublication] = []
        var seenHostPorts: Set<UInt16> = []
        for value in values {
            guard let publication = PortPublication(value) else {
                throw PortPublicationError.malformed(value)
            }
            guard seenHostPorts.insert(publication.hostPort).inserted else {
                throw PortPublicationError.duplicateHostPort(publication.hostPort)
            }
            result.append(publication)
        }
        return result
    }
}

/// Diagnostics for parsing `--publish` values.
public enum PortPublicationError: Error, Sendable, Equatable, LocalizedError {

    /// The value did not match `<host>:<guest>` or `<port>`, or used
    /// port zero, which cannot be forwarded.
    case malformed(String)

    /// Two publications requested the same host port.
    case duplicateHostPort(UInt16)

    public var errorDescription: String? {
        switch self {
        case .malformed(let value):
            "'\(value)' is not a valid port publication."
        case .duplicateHostPort(let port):
            "Host port \(port) is published twice."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .malformed:
            "Use --publish <hostPort>:<guestPort> (for example --publish 8080:18789) or --publish <port> to use the same number on both sides. Ports must be between 1 and 65535."
        case .duplicateHostPort:
            "Give each --publish a distinct host port."
        }
    }
}

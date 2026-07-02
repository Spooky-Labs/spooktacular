import Foundation

/// The outermost framing of every chunk written to, or read
/// from, the virtio serial port presented to the guest by
/// Apple's `VZSpiceAgentPortAttachment`.
///
/// Wire layout (little-endian, packed, 8 bytes):
///
/// ```
/// offset  size  field
/// 0       4     port  (UInt32)   — always VDP_CLIENT_PORT (1)
///                                  from a guest agent
/// 4       4     size  (UInt32)   — byte count of the
///                                  payload that follows
/// ```
///
/// The host demultiplexes chunks by `port`. In practice
/// guest-to-host traffic is always `port = 1` (client-side of
/// the virtio channel); the `VDP_SERVER_PORT = 2` direction is
/// host-to-guest from the SPICE server's point of view, but
/// through the Virtualization framework the host doesn't use
/// it — Apple's bridge encapsulates its messages on port 1.
public struct VDIChunkHeader: Equatable, Sendable {

    /// Port identifier. Standard value is
    /// ``VDIChunkHeader/clientPort`` (1).
    public var port: UInt32

    /// Number of bytes immediately following this header,
    /// covering the ``VDAgentMessage`` header and its payload
    /// combined.
    public var size: UInt32

    public static let clientPort: UInt32 = 1
    public static let serverPort: UInt32 = 2

    /// Fixed on-wire size of the header (8 bytes).
    public static let byteCount: Int = 8

    public init(port: UInt32 = Self.clientPort, size: UInt32) {
        self.port = port
        self.size = size
    }
}

/// The per-message header that follows a ``VDIChunkHeader``.
///
/// Wire layout (little-endian, packed, 20 bytes):
///
/// ```
/// offset  size  field
/// 0       4     protocol (UInt32)  — VD_AGENT_PROTOCOL (1)
/// 4       4     type     (UInt32)  — one of VDAgentMessageType
/// 8       8     opaque   (UInt64)  — reserved, ignored
///                                    for clipboard ops
/// 16      4     size     (UInt32)  — payload byte count
/// ```
///
/// The payload immediately follows, `size` bytes long.
public struct VDAgentMessage: Equatable, Sendable {

    /// Protocol version. The spec has only ever defined
    /// version 1 (`VD_AGENT_PROTOCOL`). All agents use 1.
    public var protocolVersion: UInt32

    /// Numeric message type — see ``VDAgentMessageType``.
    public var type: UInt32

    /// Reserved field. Senders set to 0; receivers must
    /// ignore. The name "opaque" is the SPICE spec's — it
    /// was designed for future extensibility and never
    /// used in practice.
    public var opaque: UInt64

    /// Size of the payload that immediately follows this
    /// header, in bytes.
    public var size: UInt32

    /// Current protocol version per the SPICE specification.
    public static let currentProtocolVersion: UInt32 = 1

    /// Fixed on-wire size of the header (20 bytes).
    public static let byteCount: Int = 20

    public init(
        protocolVersion: UInt32 = Self.currentProtocolVersion,
        type: UInt32,
        opaque: UInt64 = 0,
        size: UInt32
    ) {
        self.protocolVersion = protocolVersion
        self.type = type
        self.opaque = opaque
        self.size = size
    }

    /// Convenience initializer that takes a typed message.
    public init(
        type: VDAgentMessageType,
        size: UInt32
    ) {
        self.init(type: type.rawValue, size: size)
    }
}

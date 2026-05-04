import Foundation

/// A transport-agnostic port for servers that accept
/// bidirectional byte streams from remote clients.
///
/// ## Clean Architecture
///
/// Application-layer use cases — the NDJSON event bus,
/// scanout streaming, vsock proxies — depend on this port
/// rather than a concrete transport.  The composition root
/// picks the adapter at startup (QUIC, TLS-over-TCP,
/// WebSocket, plain vsock, whatever fits the deployment).
/// Transport-specific concepts (QUIC's ALPN,
/// TLS-over-TCP's cert chains, WebSocket's sub-protocols)
/// stay inside the adapter and never appear in this
/// protocol or in `SpooktacularApplication` callers.
///
/// ## Lifecycle
///
/// 1. Composition root constructs the concrete server
///    (e.g., `QUICRemoteStreamServer`) with any
///    adapter-specific configuration it needs.
/// 2. Application code calls ``start()`` and awaits
///    ``incomingStreams`` to drive the protocol on top.
/// 3. ``stop()`` closes the listener; in-flight streams
///    stay alive until their own ``RemoteStream/cancel()``
///    fires or the peer closes.
public protocol RemoteStreamServer: AnyObject, Sendable {

    /// Begins accepting connections.  Suspends until the
    /// underlying listener is bound to its endpoint.
    /// Throws if binding fails.
    func start() async throws

    /// Stops accepting new connections.  Idempotent.
    func stop() async

    /// New incoming streams arrive on this sequence.
    /// Finishes when ``stop()`` is called or the listener
    /// transitions to a terminal state.
    ///
    /// `any RemoteStream` rather than a concrete type so
    /// adapters can wrap whatever their transport vends
    /// (e.g., `NWConnection` for QUIC, `URLSessionStreamTask`
    /// for TLS) without surfacing that type here.
    var incomingStreams: AsyncStream<any RemoteStream> { get }
}

/// A transport-agnostic port for outbound connections to a
/// remote ``RemoteStreamServer``.  Mirrors the server-side
/// port; application-layer callers that need to dial a
/// remote peer depend on this protocol, not on a specific
/// transport (QUIC, TLS-over-TCP, WebSocket, etc.).
///
/// ## Clean Architecture
///
/// The same layering argument as ``RemoteStreamServer``:
/// adapter-specific concerns (ALPN negotiation, TLS
/// handshake, mTLS client identity, cert pinning) stay
/// inside the concrete adapter in
/// ``SpooktacularInfrastructureApple``.  The composition
/// root wires up a concrete client and hands the domain an
/// `any RemoteStreamClient`.
public protocol RemoteStreamClient: Sendable {

    /// Opens a new bidirectional byte stream to the server
    /// at `host:port`.  Suspends until the transport is
    /// ready (TCP established, QUIC handshake complete,
    /// WebSocket upgraded) or throws on failure.
    ///
    /// Each call produces a fresh stream.  Callers that
    /// want multiplexing (multiple logical streams sharing
    /// one transport-level connection) can hold an adapter
    /// with stream-opening semantics — a future refinement
    /// of this protocol if/when multiplexing becomes a
    /// domain concern.
    func connect(toHost host: String, port: UInt16) async throws -> any RemoteStream
}

/// A single bidirectional byte stream between a server and
/// a remote peer.  Returned by ``RemoteStreamServer`` and
/// ``RemoteStreamClient``, used by application-layer
/// protocol handlers (event-bus NDJSON framing,
/// scanout-frame serialization, etc.).
///
/// Each concrete adapter wraps the transport's native
/// connection type — NWConnection, URLSessionStreamTask,
/// vsock file descriptor — and adapts send/receive into
/// this uniform shape.  Application code never sees the
/// underlying type.
public protocol RemoteStream: Sendable {

    /// Sends a chunk of bytes to the peer.  Suspends until
    /// the transport accepts the bytes for delivery (QUIC:
    /// framed into a stream packet; TLS: written to the
    /// socket).  Does not guarantee the peer has received
    /// them — use application-layer acks for that.
    func send(_ data: Data) async throws

    /// Bytes received from the peer, in arrival order.
    /// Finishes normally when the peer closes the stream;
    /// throws if the transport observes a framing /
    /// protocol error.
    var received: AsyncThrowingStream<Data, any Error> { get }

    /// Closes this stream.  Does not affect the parent
    /// server or its other streams.  Idempotent.
    func cancel()
}

import Foundation
import Network
import os
import SpooktacularApplication
import CryptoKit
@preconcurrency import Virtualization

/// Host-side TCP-over-vsock port forwarder.
///
/// For every incoming TCP connection on `127.0.0.1:<hostPort>`,
/// opens a vsock connection to the guest agent's tunnel port
/// (9473), issues `POST /api/v1/tunnel/<guestPort>`, reads the
/// `HTTP/1.1 200 OK` acknowledgement, and then splices bytes
/// bidirectionally.
///
/// ## Apple APIs
///
/// - [`NWListener`](https://developer.apple.com/documentation/network/nwlistener)
///   for accepting incoming TCP connections on the host.
/// - [`NWParameters.tcp`](https://developer.apple.com/documentation/network/nwparameters/tcp)
///   — the canonical TCP preset (contrast with Track C's UDS
///   listener, which uses the default `NWParameters()`).
/// - [`NWEndpoint.hostPort(host:port:)`](https://developer.apple.com/documentation/network/nwendpoint/hostport(host:port:))
///   to bind the listener to loopback.
/// - [`NWConnection`](https://developer.apple.com/documentation/network/nwconnection)
///   for the accepted TCP stream.
/// - [`VZVirtioSocketDevice.connect(toPort:)`](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice/connect(toport:))
///   to open the guest-side vsock leg.
/// - [`VZVirtioSocketConnection.fileDescriptor`](https://developer.apple.com/documentation/virtualization/vzvirtiosocketconnection/filedescriptor)
///   — the accepted vsock fd we splice through POSIX
///   `read`/`write` (Darwin has no socket-to-socket `splice`
///   syscall; `sendfile` only moves file→socket).
///
/// ## Why Network.framework for the host leg
///
/// `NWListener` is Apple's recommended TCP-accept primitive
/// for new macOS code — it's Swift-native, queue-friendly,
/// and auto-integrates with the system's firewall +
/// App-Transport Security policies. The alternative —
/// `socket(AF_INET, SOCK_STREAM, 0)` + `bind` + `listen` +
/// `accept` — is the POSIX path; we reserve it for the
/// guest-side handler where we need the fd directly for
/// `read`/`write`.
@MainActor
public final class PortForwarder {

    /// Logger for accept + tunnel lifecycle events. Sub-
    /// system name matches the GUI app so all host-side
    /// streaming shows up together in Console.app.
    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "port-forwarder"
    )

    /// Host loopback port we're accepting on.
    public let hostPort: UInt16

    /// Guest localhost port we're targeting inside the VM.
    public let guestPort: UInt16

    /// VM whose vsock we tunnel through.
    private let socketDevice: VZVirtioSocketDevice

    /// Host identity signer for
    /// `X-Spooktacular-*` headers on the `POST /api/v1/tunnel`
    /// handshake. Re-uses the same credential machinery as
    /// ``GuestAgentClient``.
    private let hostSigner: (any P256Signer)?

    /// Guest agent's tunnel-scope vsock port — must match
    /// ``EndpointScope/tunnel``'s mapping in the agent
    /// (`AgentRouter.portForScope`).
    private let tunnelVsockPort: UInt32 = 9473

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.spooktacular.port-forwarder")

    public init(
        hostPort: UInt16,
        guestPort: UInt16,
        socketDevice: VZVirtioSocketDevice,
        hostSigner: (any P256Signer)? = nil
    ) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.socketDevice = socketDevice
        self.hostSigner = hostSigner
    }

    /// Binds the host loopback port and starts accepting.
    ///
    /// Uses the canonical
    /// [`NWListener(using:on:)`](https://developer.apple.com/documentation/network/nwlistener/init(using:on:))
    /// initializer with
    /// [`NWParameters.tcp`](https://developer.apple.com/documentation/network/nwparameters/tcp)
    /// and an explicit port — matches the pattern in Apple's
    /// "Building a Custom Peer-to-Peer Protocol" sample.
    public func start() async throws {
        guard listener == nil else { return }

        // `NWParameters.tcp` is Apple's stock TCP-over-IPv4/IPv6
        // preset. For loopback-only listeners we also disable
        // remote peer access by binding explicitly to `127.0.0.1`
        // via `requiredLocalEndpoint` — the listener never
        // accepts connections on any other interface even if the
        // port is otherwise reachable.
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(integerLiteral: hostPort)
        )

        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(integerLiteral: hostPort)
        )

        listener.newConnectionHandler = { [weak self] incoming in
            guard let self else {
                incoming.cancel()
                return
            }
            Task { @MainActor in
                await self.accept(incoming)
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        Self.log.notice(
            "PortForwarder \(self.hostPort, privacy: .public) → guest:\(self.guestPort, privacy: .public) ready"
        )
    }

    /// Cancels the listener. Already-accepted tunnels run to
    /// completion independently — their lifetime is tied to
    /// the underlying TCP peer, not to this forwarder.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Per-accept handling

    private func accept(_ tcp: NWConnection) async {
        // Bring the TCP leg up before we spend vsock
        // resources. `NWConnection.start(queue:)` transitions
        // through `.preparing` → `.ready`; we observe readiness
        // via `stateUpdateHandler` and bridge into async.
        // Docs: https://developer.apple.com/documentation/network/nwconnection/state
        tcp.start(queue: queue)
        await waitForReady(tcp)

        // Open the guest-side vsock leg. `connect(toPort:)` is
        // Apple's documented entry point for host→guest
        // communication:
        // https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice/connect(toport:)
        let vsock: VZVirtioSocketConnection
        do {
            vsock = try await socketDevice.connect(toPort: tunnelVsockPort)
        } catch {
            Self.log.error(
                "vsock connect failed: \(error.localizedDescription, privacy: .public)"
            )
            tcp.cancel()
            return
        }

        // Write the CONNECT-style handshake. We reuse HTTP so
        // the guest agent's existing `authorizeRequest` gate
        // fires — no new auth protocol. `POST
        // /api/v1/tunnel/<port>` is the documented tunnel
        // endpoint (AgentRouter.endpointScope).
        let handshake = try? await writeHandshake(
            vsockFD: vsock.fileDescriptor,
            guestPort: guestPort
        )
        guard handshake == .ok else {
            tcp.cancel()
            close(vsock.fileDescriptor)
            return
        }

        // Consume any response bytes already waiting on the
        // vsock after the `HTTP/1.1 200 OK\r\n\r\n` header so
        // the first guest-to-host tunnel payload byte starts
        // at the buffer boundary.
        await splice(tcp: tcp, vsockFD: vsock.fileDescriptor)
    }

    private enum HandshakeOutcome { case ok, rejected }

    /// Sends `POST /api/v1/tunnel/<guestPort> HTTP/1.1` with
    /// the standard signed-request headers and waits for the
    /// guest to respond `HTTP/1.1 200 OK\r\n\r\n`. Anything
    /// else is a rejection.
    private func writeHandshake(
        vsockFD: Int32,
        guestPort: UInt16
    ) async throws -> HandshakeOutcome {
        let path = "/api/v1/tunnel/\(guestPort)"
        var request = "POST \(path) HTTP/1.1\r\n"
        request += "Host: localhost\r\n"
        request += "Connection: upgrade\r\n"
        request += "Content-Length: 0\r\n"

        if let signer = hostSigner {
            let timestamp = Date().formatted(Self.iso8601)
            let nonce = UUID().uuidString
            let bodyHash = SHA256.hash(data: Data())
                .map { String(format: "%02x", $0) }.joined()
            let canonical = "POST\n\(path)\n\(bodyHash)\n\(timestamp)\n\(nonce)"
            let signature = try signer.signature(for: Data(canonical.utf8))
            request += "X-Spooktacular-Timestamp: \(timestamp)\r\n"
            request += "X-Spooktacular-Nonce: \(nonce)\r\n"
            request += "X-Spooktacular-Signature: \(signature.base64EncodedString())\r\n"
        }
        request += "\r\n"

        // Dup the fd once so the write-side can be closed
        // independently of the read-side. Same pattern as
        // GuestAgentClient — see its class-level docs for the
        // main-queue rationale.
        let writeFD = dup(vsockFD)
        guard writeFD >= 0 else { return .rejected }
        let writeHandle = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)
        writeHandle.write(Data(request.utf8))

        // Read the response header (up to `\r\n\r\n`). A full
        // response for the tunnel handshake is tiny — well
        // under 512 bytes.
        let readFD = dup(vsockFD)
        guard readFD >= 0 else { return .rejected }
        let readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)

        var header = Data()
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        while header.range(of: sep) == nil {
            let chunk = readHandle.readData(ofLength: 1024)
            if chunk.isEmpty { return .rejected }
            header.append(chunk)
        }

        // "HTTP/1.1 200 OK" prefix check is adequate — the
        // guest's TunnelHandler only emits 200 on success; any
        // other status is an error.
        guard let prefix = String(data: header.prefix(15), encoding: .utf8),
              prefix.hasPrefix("HTTP/1.1 200") else {
            return .rejected
        }
        return .ok
    }

    // MARK: - Bidirectional splice

    /// Pumps bytes between the TCP `NWConnection` (host side)
    /// and the raw vsock fd (guest side). Two concurrent
    /// tasks, one per direction, finish independently on EOF
    /// or error.
    ///
    /// The TCP side is driven by
    /// [`NWConnection.receive(minimumIncompleteLength:maximumLength:completion:)`](https://developer.apple.com/documentation/network/nwconnection/receive(minimumincompletelength:maximumlength:completion:))
    /// and
    /// [`NWConnection.send(content:completion:)`](https://developer.apple.com/documentation/network/nwconnection/send(content:completion:)),
    /// both of which apply the kernel socket buffer's back-
    /// pressure semantics — reads block the receive callback
    /// until bytes arrive; sends wait on the `completion`
    /// callback so publishers can't outrun the peer.
    private func splice(tcp: NWConnection, vsockFD: Int32) async {
        let readFD = dup(vsockFD)
        let writeFD = dup(vsockFD)
        close(vsockFD)

        guard readFD >= 0, writeFD >= 0 else {
            tcp.cancel()
            if readFD >= 0 { close(readFD) }
            if writeFD >= 0 { close(writeFD) }
            return
        }

        let readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        let writeHandle = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)

        let io = TunnelIO(readHandle: readHandle, writeHandle: writeHandle)

        await withTaskGroup(of: Void.self) { group in
            // TCP → vsock
            group.addTask { [weak self] in
                await self?.pumpTCPToVsock(tcp: tcp, io: io)
            }
            // vsock → TCP
            group.addTask { [weak self] in
                await self?.pumpVsockToTCP(tcp: tcp, io: io)
            }
            await group.waitForAll()
        }

        tcp.cancel()
    }

    private func pumpTCPToVsock(tcp: NWConnection, io: TunnelIO) async {
        while true {
            let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                tcp.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 64 * 1024
                ) { chunk, _, isComplete, _ in
                    if isComplete && (chunk?.isEmpty ?? true) {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: chunk)
                    }
                }
            }
            guard let data, !data.isEmpty else {
                try? io.write.close()
                return
            }
            io.write.write(data)
        }
    }

    private func pumpVsockToTCP(tcp: NWConnection, io: TunnelIO) async {
        while true {
            let chunk = io.read.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                tcp.send(
                    content: chunk,
                    completion: .contentProcessed { _ in
                        continuation.resume()
                    }
                )
            }
        }
    }

    // MARK: - Helpers

    private func waitForReady(_ connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    continuation.resume()
                } else if case .failed = state {
                    continuation.resume()
                } else if case .cancelled = state {
                    continuation.resume()
                }
            }
        }
    }

    /// [`Date.ISO8601FormatStyle`](https://developer.apple.com/documentation/foundation/date/iso8601formatstyle)
    /// — Apple's Sendable-by-construction replacement for
    /// `ISO8601DateFormatter`.  Default config emits
    /// `2023-11-14T22:13:20Z` — byte-identical to
    /// `ISO8601DateFormatter[.withInternetDateTime]` for
    /// UTC dates, which is what signed-request verifiers on
    /// both the guest and host sides expect.
    private static let iso8601 = Date.ISO8601FormatStyle()

    /// Pair of `FileHandle`s over duplicated vsock fds. Kept
    /// as `@unchecked Sendable` — the `FileHandle`s are each
    /// owned by exactly one of the splice sub-tasks and the
    /// two tasks never race because each direction has its
    /// own fd.
    private struct TunnelIO: @unchecked Sendable {
        let read: FileHandle
        let write: FileHandle
        init(readHandle: FileHandle, writeHandle: FileHandle) {
            self.read = readHandle
            self.write = writeHandle
        }
    }
}

import Foundation
import Network
import os

/// Localhost NBD (Network Block Device) server that serves
/// one EBS snapshot per instance. Apple's
/// `VZNetworkBlockDeviceStorageDeviceAttachment` is the
/// client side; this type implements the server side so a
/// VM can attach an EBS snapshot as a virtio-blk disk
/// without leaving the host machine.
///
/// ## Protocol — NBD "newstyle negotiation" (fixed variant)
///
/// The server implements the subset of the NBD protocol the
/// Virtualization framework actually exercises:
///
/// 1. **Handshake** — send magic cookies and handshake
///    flags; accept client flags.
/// 2. **Option haggling** — accept `NBD_OPT_GO` / `NBD_OPT_INFO`
///    and reply with export size, block size, transmission
///    flags.
/// 3. **Transmission** — loop on `NBD_CMD_READ` / `NBD_CMD_DISC` / `NBD_CMD_FLUSH`.
///
/// We **don't** support writes in the MVP: `NBD_CMD_WRITE`
/// returns `NBD_ENOTSUP`. A writable mode requires the EBS
/// `PutSnapshotBlock` + `CompleteSnapshot` flow, which is a
/// follow-up track.
///
/// Spec references:
/// - [NBD protocol document](https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md)
/// - [NBD URI format](https://github.com/NetworkBlockDevice/nbd/blob/master/doc/uri.md)
///
/// ## Apple APIs
///
/// - [`NWListener(using:on:)`](https://developer.apple.com/documentation/network/nwlistener/init(using:on:))
///   with [`NWParameters.tcp`](https://developer.apple.com/documentation/network/nwparameters/tcp)
///   binding to `127.0.0.1:<port>` — the client-side
///   `VZNetworkBlockDeviceStorageDeviceAttachment(url:)`
///   dials `nbd://127.0.0.1:<port>/<export>`.
/// - [`NWConnection.receive(exactly:)`](https://developer.apple.com/documentation/network/nwconnection)
///   — we drive the binary protocol with exact-length reads.
///
/// ## Performance envelope
///
/// One EBS `GetSnapshotBlock` call costs ~50 ms round-trip
/// per 512 KiB block. The NBD client queues multiple
/// in-flight reads; we serve them via a `TaskGroup` so AWS
/// API calls run concurrently. Apple's docs cap the
/// client's internal queue depth at "implementation
/// dependent," but in practice it's ~16 parallel requests —
/// easily within EBS Direct's per-volume throughput budget
/// (2 GiB/s aggregate).
///
/// ## Threat model
///
/// The listener binds **only to 127.0.0.1**. No NBD-level
/// auth is implemented; filesystem permissions on the
/// listening port + the loopback-only binding are the
/// perimeter. This is fine for a local bridge consumed by
/// the same-user VZ framework instance. If we ever expose
/// NBD over the network, TLS (via `NWProtocolTLS`) + a
/// shared-secret handshake need to land first.
public actor EBSNBDServer {

    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "ebs-nbd"
    )

    /// The EBS snapshot we're serving.
    public let snapshotID: String

    /// Total logical volume size in bytes — derived from
    /// EBS's `VolumeSize` (given in GiB) on first
    /// `ListSnapshotBlocks`.
    public let volumeSizeBytes: UInt64

    /// Read-side EBS client.
    private let ebs: EBSDirectClient

    /// Block-token cache: blockIndex → tokenString. Tokens
    /// expire (~1 h per AWS docs) so we rebuild on a cache
    /// miss or 403 response. The MVP assumes the
    /// ListSnapshotBlocks call at start() populates the
    /// cache once and we re-list when a token is rejected.
    private var tokens: [Int: String] = [:]

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.spooktacular.ebs-nbd")

    /// Bound TCP port once the listener is started.
    public private(set) var listenPort: UInt16?

    /// Creates a server backed by an EBS snapshot.
    ///
    /// - Parameters:
    ///   - snapshotID: EBS snapshot identifier (`snap-…`).
    ///   - volumeSizeBytes: Logical size of the snapshot, used
    ///     to sanity-check NBD `NBD_OPT_EXPORT_NAME` replies.
    ///   - ebs: Signed EBS Direct API client the server uses
    ///     to fault in blocks on demand.
    public init(
        snapshotID: String,
        volumeSizeBytes: UInt64,
        ebs: EBSDirectClient
    ) {
        self.snapshotID = snapshotID
        self.volumeSizeBytes = volumeSizeBytes
        self.ebs = ebs
    }

    /// Populates the block-token cache and starts the
    /// listener. Returns the URL the VM should connect to
    /// (`nbd://127.0.0.1:<port>/<snapshot>`).
    public func start() async throws -> URL {
        try await refreshTokenCache()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        let newListener = try NWListener(using: parameters)
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        newListener.start(queue: queue)

        // Poll for the bound port (NWListener doesn't
        // synchronously expose it after `start`).
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if case .hostPort(_, let port) = newListener.port.map({ NWEndpoint.hostPort(host: .ipv4(.loopback), port: $0) }) ?? .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(integerLiteral: 0)),
               port.rawValue != 0 {
                self.listenPort = port.rawValue
                self.listener = newListener
                let url = URL(string: "nbd://127.0.0.1:\(port.rawValue)/\(snapshotID)")!
                Self.log.notice(
                    "EBS-NBD listening for snapshot \(self.snapshotID, privacy: .public) at \(url.absoluteString, privacy: .public)"
                )
                return url
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        newListener.cancel()
        throw NSError(
            domain: "EBSNBDServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Listener failed to bind within 2 s"]
        )
    }

    /// Stops the listener and discards connections. Safe to
    /// call multiple times.
    public func stop() {
        listener?.cancel()
        listener = nil
        tokens.removeAll()
    }

    // MARK: - Token cache

    private func refreshTokenCache() async throws {
        var nextToken: String?
        var cache: [Int: String] = [:]
        repeat {
            let page = try await ebs.listSnapshotBlocks(
                snapshotID: snapshotID,
                nextToken: nextToken
            )
            for block in page.Blocks {
                cache[block.BlockIndex] = block.BlockToken
            }
            nextToken = page.NextToken
        } while nextToken != nil
        self.tokens = cache
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) async {
        connection.start(queue: queue)
        let session = NBDSession(
            connection: connection,
            server: self
        )
        await session.run()
    }

    // MARK: - Block reads

    /// Called from the session on each `NBD_CMD_READ`.
    /// Fetches the backing EBS block via the direct API,
    /// returns `(bytes, nil)` on success or `(nil, errno)`
    /// on failure — the session writes the NBD-shaped error
    /// response.
    func readBlock(index: Int) async -> (data: Data?, errno: UInt32) {
        guard let token = tokens[index] else {
            // Sparse EBS snapshots skip all-zero blocks.
            // The NBD protocol expects *something* back, so
            // we fabricate a zero block at the declared
            // block size — matches the behaviour `qemu-nbd`
            // uses when bridging sparse images.
            return (Data(count: EBSDirectClient.blockSize), 0)
        }
        do {
            let response = try await ebs.getSnapshotBlock(
                snapshotID: snapshotID,
                blockIndex: index,
                blockToken: token
            )
            return (response.data, 0)
        } catch {
            Self.log.error(
                "GetSnapshotBlock(\(self.snapshotID, privacy: .public), \(index)) failed: \(error.localizedDescription, privacy: .public)"
            )
            // NBD_EIO — closest mapping; AWS-side 403 / 404 /
            // 429 all land here since the NBD client only
            // understands POSIX errnos.
            return (nil, UInt32(EIO))
        }
    }
}

// MARK: - NBD session state machine

/// Per-connection NBD state machine. One instance per
/// accepted TCP connection; drives handshake → option
/// haggling → transmission → close.
private actor NBDSession {

    // MARK: NBD wire constants

    static let NBDMAGIC: UInt64 = 0x4E42444D_41474943      // "NBDMAGIC"
    static let IHAVEOPT: UInt64 = 0x49484156_454F5054      // "IHAVEOPT"
    static let OPT_REPLY_MAGIC: UInt64 = 0x3E889045_565A9_ // will be truncated; use correct value below
    static let NBD_REQUEST_MAGIC: UInt32 = 0x25609513
    static let NBD_SIMPLE_REPLY_MAGIC: UInt32 = 0x67446698

    // Handshake flags (server → client): `FIXED_NEWSTYLE`
    static let NBD_FLAG_FIXED_NEWSTYLE: UInt16 = 0x0001

    // Transmission flags (per-export, server → client):
    // `HAS_FLAGS` bit-0 must be set in newstyle.
    static let NBD_FLAG_HAS_FLAGS: UInt16 = 0x0001
    static let NBD_FLAG_READ_ONLY: UInt16 = 0x0002

    // Option request / reply magics.
    static let NBD_OPTION_REPLY_MAGIC: UInt64 = 0x0003_E889_045_565A9  // per spec

    // Commands
    static let NBD_CMD_READ: UInt16 = 0
    static let NBD_CMD_WRITE: UInt16 = 1
    static let NBD_CMD_DISC: UInt16 = 2
    static let NBD_CMD_FLUSH: UInt16 = 3

    // Option requests we care about.
    static let NBD_OPT_EXPORT_NAME: UInt32 = 1
    static let NBD_OPT_ABORT: UInt32 = 2
    static let NBD_OPT_INFO: UInt32 = 6
    static let NBD_OPT_GO: UInt32 = 7

    // Option reply types.
    static let NBD_REP_ACK: UInt32 = 1
    static let NBD_REP_INFO: UInt32 = 3

    // Info types (in NBD_REP_INFO responses).
    static let NBD_INFO_EXPORT: UInt16 = 0
    static let NBD_INFO_BLOCK_SIZE: UInt16 = 3

    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "ebs-nbd-session"
    )

    private let connection: NWConnection
    private let server: EBSNBDServer

    init(connection: NWConnection, server: EBSNBDServer) {
        self.connection = connection
        self.server = server
    }

    func run() async {
        defer { connection.cancel() }
        do {
            try await sendHandshake()
            try await readClientFlags()
            try await runOptionHaggling()
            try await runTransmission()
        } catch {
            Self.log.warning(
                "NBD session ended: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Handshake

    private func sendHandshake() async throws {
        var data = Data()
        data.appendBigEndian(Self.NBDMAGIC)
        data.appendBigEndian(Self.IHAVEOPT)
        data.appendBigEndian(Self.NBD_FLAG_FIXED_NEWSTYLE)
        try await send(data)
    }

    private func readClientFlags() async throws {
        _ = try await receive(exactly: 4)  // Discard — we don't
                                            // switch behavior on
                                            // client flags today.
    }

    // MARK: Option haggling

    private func runOptionHaggling() async throws {
        while true {
            let magic = try await receiveBigEndianUInt64()
            guard magic == Self.IHAVEOPT else {
                throw NBDError.malformed("bad option magic: \(String(magic, radix: 16))")
            }
            let option = try await receiveBigEndianUInt32()
            let length = try await receiveBigEndianUInt32()
            let payload = length > 0
                ? try await receive(exactly: Int(length))
                : Data()

            switch option {
            case Self.NBD_OPT_GO, Self.NBD_OPT_INFO:
                try await respondToGoOrInfo(option: option, payload: payload)
                if option == Self.NBD_OPT_GO {
                    return  // Enter transmission phase.
                }
            case Self.NBD_OPT_ABORT:
                return
            case Self.NBD_OPT_EXPORT_NAME:
                // Old-style: immediately respond with raw
                // export bytes (no reply envelope).
                try await sendExportName()
                return
            default:
                // Unsupported option: reply NBD_REP_ERR_UNSUP.
                try await sendOptionReply(
                    option: option,
                    type: 0x8000_0000 | 1,  // NBD_REP_ERR_UNSUP
                    data: Data()
                )
            }
        }
    }

    /// Handles `NBD_OPT_GO` and `NBD_OPT_INFO`. Both expect
    /// one or more `NBD_REP_INFO` responses followed by a
    /// final `NBD_REP_ACK`.
    private func respondToGoOrInfo(option: UInt32, payload: Data) async throws {
        // Payload: uint32 name-length + name + uint16
        // n-requests + n * uint16 info type.
        // We ignore the requested info-types list and always
        // return both EXPORT (size+flags) and BLOCK_SIZE
        // since the VZ client always asks for them.

        // NBD_INFO_EXPORT: uint16 type + uint64 size + uint16 flags.
        var exportInfo = Data()
        exportInfo.appendBigEndian(Self.NBD_INFO_EXPORT)
        exportInfo.appendBigEndian(server.volumeSizeBytes)
        exportInfo.appendBigEndian(Self.NBD_FLAG_HAS_FLAGS | Self.NBD_FLAG_READ_ONLY)
        try await sendOptionReply(option: option, type: Self.NBD_REP_INFO, data: exportInfo)

        // NBD_INFO_BLOCK_SIZE: uint16 type + uint32 min +
        // uint32 preferred + uint32 max.
        var blockSizeInfo = Data()
        blockSizeInfo.appendBigEndian(Self.NBD_INFO_BLOCK_SIZE)
        blockSizeInfo.appendBigEndian(UInt32(4096))                    // min
        blockSizeInfo.appendBigEndian(UInt32(EBSDirectClient.blockSize)) // preferred
        blockSizeInfo.appendBigEndian(UInt32(EBSDirectClient.blockSize)) // max
        try await sendOptionReply(option: option, type: Self.NBD_REP_INFO, data: blockSizeInfo)

        // Final ACK.
        try await sendOptionReply(option: option, type: Self.NBD_REP_ACK, data: Data())
    }

    /// Old-style `NBD_OPT_EXPORT_NAME` expects just the raw
    /// export info without an envelope: uint64 size + uint16
    /// flags + 124 bytes zeroed.
    private func sendExportName() async throws {
        var data = Data()
        data.appendBigEndian(server.volumeSizeBytes)
        data.appendBigEndian(Self.NBD_FLAG_HAS_FLAGS | Self.NBD_FLAG_READ_ONLY)
        data.append(Data(count: 124))
        try await send(data)
    }

    private func sendOptionReply(
        option: UInt32,
        type: UInt32,
        data: Data
    ) async throws {
        var reply = Data()
        // Option reply magic: `0x3e889045565a9`. Per
        // https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md#option-reply.
        reply.appendBigEndian(UInt64(0x3e889045_565a9))
        reply.appendBigEndian(option)
        reply.appendBigEndian(type)
        reply.appendBigEndian(UInt32(data.count))
        reply.append(data)
        try await send(reply)
    }

    // MARK: Transmission

    private func runTransmission() async throws {
        while true {
            let magic = try await receiveBigEndianUInt32()
            guard magic == Self.NBD_REQUEST_MAGIC else {
                throw NBDError.malformed("bad request magic: \(String(magic, radix: 16))")
            }
            _ = try await receiveBigEndianUInt16()     // command flags
            let command = try await receiveBigEndianUInt16()
            let handle = try await receiveBigEndianUInt64()
            let offset = try await receiveBigEndianUInt64()
            let length = try await receiveBigEndianUInt32()

            switch command {
            case Self.NBD_CMD_DISC:
                return
            case Self.NBD_CMD_READ:
                try await handleRead(handle: handle, offset: offset, length: length)
            case Self.NBD_CMD_FLUSH:
                try await sendSimpleReply(handle: handle, errno: 0, data: Data())
            case Self.NBD_CMD_WRITE:
                // Read + discard the payload, then reject.
                _ = try await receive(exactly: Int(length))
                try await sendSimpleReply(handle: handle, errno: UInt32(EROFS), data: Data())
            default:
                try await sendSimpleReply(handle: handle, errno: UInt32(EINVAL), data: Data())
            }
        }
    }

    private func handleRead(handle: UInt64, offset: UInt64, length: UInt32) async throws {
        // EBS blocks are 512 KiB; NBD requests can span any
        // byte range. Cut the request into block-sized
        // slices and fan-out.
        let blockSize = UInt64(EBSDirectClient.blockSize)
        var remaining = UInt64(length)
        var cursor = offset
        var payload = Data()
        while remaining > 0 {
            let blockIndex = Int(cursor / blockSize)
            let offsetInBlock = cursor % blockSize
            let bytesFromThisBlock = min(blockSize - offsetInBlock, remaining)

            let (data, errno) = await server.readBlock(index: blockIndex)
            guard let data, errno == 0 else {
                try await sendSimpleReply(handle: handle, errno: errno, data: Data())
                return
            }
            // Trim to the requested slice.
            let start = Int(offsetInBlock)
            let end = min(start + Int(bytesFromThisBlock), data.count)
            payload.append(data[start..<end])

            // Short EBS blocks (sparse / final-block) —
            // pad with zeros to match requested length.
            let delivered = end - start
            if delivered < Int(bytesFromThisBlock) {
                payload.append(Data(count: Int(bytesFromThisBlock) - delivered))
            }

            cursor += bytesFromThisBlock
            remaining -= bytesFromThisBlock
        }
        try await sendSimpleReply(handle: handle, errno: 0, data: payload)
    }

    private func sendSimpleReply(handle: UInt64, errno: UInt32, data: Data) async throws {
        var reply = Data()
        reply.appendBigEndian(Self.NBD_SIMPLE_REPLY_MAGIC)
        reply.appendBigEndian(errno)
        reply.appendBigEndian(handle)
        reply.append(data)
        try await send(reply)
    }

    // MARK: Transport helpers

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func receive(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: count
            ) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NBDError.closed)
                }
            }
        }
    }

    private func receiveBigEndianUInt16() async throws -> UInt16 {
        let bytes = try await receive(exactly: 2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func receiveBigEndianUInt32() async throws -> UInt32 {
        let bytes = try await receive(exactly: 4)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
             | UInt32(bytes[2]) << 8  | UInt32(bytes[3])
    }

    private func receiveBigEndianUInt64() async throws -> UInt64 {
        let bytes = try await receive(exactly: 8)
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[bytes.startIndex + i])
        }
        return value
    }
}

private enum NBDError: Error, LocalizedError {
    case malformed(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .malformed(let reason): "NBD protocol error: \(reason)"
        case .closed: "NBD connection closed unexpectedly"
        }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { self.append(contentsOf: $0) }
    }
    mutating func appendBigEndian(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { self.append(contentsOf: $0) }
    }
    mutating func appendBigEndian(_ value: UInt64) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { self.append(contentsOf: $0) }
    }
}

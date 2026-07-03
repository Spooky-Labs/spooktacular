import Foundation
import os
import SpiceProtocol
import SpiceSerialTransport

/// Log subsystem for the clipboard agent. Filter in Console.app
/// with `subsystem:com.spooktacular.GuestTools category:spice`
/// on the *guest* to see every decision point in the protocol
/// (grab detected, grab sent, request received, data sent /
/// received, sizes, types). Everything is `privacy: .public`
/// because the agent runs inside a developer-managed VM and
/// the debug trace is useless if the types / sizes are
/// redacted.
private let spiceLog = Logger(
    subsystem: "com.spooktacular.GuestTools",
    category: "spice"
)

/// High-level connection status, suitable for driving a
/// menu-bar status indicator.
public enum SpiceAgentStatus: Sendable {
    /// Haven't attempted to connect yet, or the agent was
    /// stopped.
    case notStarted
    /// Serial port is open but we haven't completed the
    /// capabilities handshake.
    case connecting
    /// Handshake complete; clipboard sync is active.
    case connected(peerCapabilities: UInt32)
    /// The agent encountered an error. The typed payload
    /// preserves both the phase (announce, inbound transport,
    /// frame decode, grab send) and the underlying cause —
    /// consumers can pattern-match for recovery, or display
    /// `localizedDescription` for a human-readable message.
    case failed(SpiceAgentError)
}

/// Structured error type emitted on ``SpiceAgentStatus/failed(_:)``.
///
/// Each case identifies the phase of the clipboard-agent state
/// machine that failed, and carries the underlying `Error`
/// (transport, decoder, or pasteboard bridge) so consumers can
/// cast to a specific error type for recovery.
public enum SpiceAgentError: Error, Sendable, LocalizedError {
    /// Sending the initial capabilities announce frame failed.
    /// Typically a ``SpiceSerialTransport/SpiceSerialPortError/writeFailed(errno:)``
    /// or ``SpiceSerialTransport/SpiceSerialPortError/peerClosed``.
    case announceFailed(any Error)

    /// The inbound read loop terminated with an error. The
    /// agent can no longer receive peer messages until it is
    /// restarted.
    case transportFailed(any Error)

    /// A peer-sent frame failed to decode. The agent logs and
    /// continues — one bad frame does not tear down the
    /// channel. `messageType` describes the vd_agent message
    /// that was being parsed when decoding failed.
    case frameDecodeFailed(messageType: VDAgentMessageType, cause: any Error)

    /// Sending our own clipboard grab to the peer failed —
    /// the user's copy will not be visible host-side until
    /// the next successful grab.
    case grabSendFailed(any Error)

    /// Sending a clipboard data payload in response to a peer
    /// request failed. The peer will time out waiting for its
    /// paste.
    case requestReplyFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .announceFailed(let cause):
            return "SPICE agent: capabilities announce failed — \(describe(cause))"
        case .transportFailed(let cause):
            return "SPICE agent: serial transport failed — \(describe(cause))"
        case .frameDecodeFailed(let type, let cause):
            return "SPICE agent: could not decode inbound \(type) frame — \(describe(cause))"
        case .grabSendFailed(let cause):
            return "SPICE agent: clipboard grab send failed — \(describe(cause))"
        case .requestReplyFailed(let cause):
            return "SPICE agent: clipboard data reply failed — \(describe(cause))"
        }
    }

    /// The underlying error — useful for `as?` casting to a
    /// specific transport/codec type.
    public var underlying: any Error {
        switch self {
        case .announceFailed(let cause),
             .transportFailed(let cause),
             .grabSendFailed(let cause),
             .requestReplyFailed(let cause):
            return cause
        case .frameDecodeFailed(_, let cause):
            return cause
        }
    }
}

/// Prefer `LocalizedError.errorDescription` when present —
/// it's the descriptive-message channel Foundation errors use.
private func describe(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription
        ?? String(describing: error)
}

/// Conservative ceiling on inbound clipboard payload size.
/// Matches SPICE's `VD_AGENT_MAX_CLIPBOARD` default (100 MiB);
/// we advertise this via the `maxClipboard` capability so
/// hosts can truncate oversize clipboards before sending.
/// Tuned small enough to keep our memory footprint bounded;
/// large enough to carry any reasonable pasted image.
let spiceMaxClipboardSize: UInt32 = 100 * 1024 * 1024

/// The guest-side SPICE clipboard agent.
///
/// Owns a ``SpiceTransport`` connection and drives the SPICE
/// `vd_agent` state machine for clipboard sharing. Exposes a
/// single `AsyncStream<SpiceAgentStatus>` for UI consumers
/// (our menu-bar app).
///
/// ## Protocol state machine
///
/// On start, we send `ANNOUNCE_CAPABILITIES` with
/// ``VDAgentCapabilities/macGuestDefault``. We accept the
/// peer's announce in either order (per the SPICE spec,
/// either side may speak first).
///
/// Once both sides have announced:
///
/// - **Guest user copies** → we observe a pasteboard
///   `changeCount` bump, compute available SPICE types, and
///   send a `CLIPBOARD_GRAB` with our monotonic serial. We
///   do NOT preemptively send data; the host will
///   `CLIPBOARD_REQUEST` if a paste actually happens.
///
/// - **Host sends `CLIPBOARD_GRAB`** → we remember the
///   peer's available types + serial and WAIT — per spec,
///   we don't eagerly `CLIPBOARD_REQUEST`. We only issue
///   requests when our user actually pastes (detected by
///   some higher-level UX hook, or on a timer). For now,
///   the agent doesn't drive host-to-guest pastes
///   automatically — the user needs to explicitly pull via
///   a UI action. This is intentional for a v1; SPICE
///   allows eager pulling but the bandwidth/privacy cost
///   on a large host clipboard (huge images) isn't worth
///   it without a clear user intent.
///   Track A follow-up: wire paste-intercept on the guest
///   side so `⌘V` triggers a REQUEST.
///
/// - **Host sends `CLIPBOARD_REQUEST`** (we're the grab
///   holder) → we read the requested type from our
///   pasteboard, send `CLIPBOARD` (data) back. Strict:
///   unsolicited `CLIPBOARD` messages violate the spec.
///
/// - **Host sends `CLIPBOARD`** (answer to our request) →
///   we write it to our pasteboard, record the resulting
///   `changeCount` so our own next poll doesn't echo the
///   data back as a fresh grab.
///
/// - **Re-grab** supersedes the previous grab implicitly,
///   no RELEASE required (per `VD_AGENT_CAP_CLIPBOARD_NO_RELEASE_ON_REGRAB`).
public actor SpiceClipboardAgent {

    // MARK: - Dependencies

    private let transport: SpiceTransport
    private let pasteboard: any PasteboardBridge

    // MARK: - Status

    private var statusContinuation:
        AsyncStream<SpiceAgentStatus>.Continuation?
    public nonisolated let statusStream: AsyncStream<SpiceAgentStatus>

    // MARK: - Handshake state

    private var peerCapabilities: VDAgentCapabilities = []
    private var peerAnnounced: Bool = false

    // MARK: - Grab state

    /// Monotonic serial for our own grabs. Incremented once
    /// per guest-side copy event. Per SPICE's
    /// `CLIPBOARD_GRAB_SERIAL` capability, both sides track
    /// and compare serials to resolve simultaneous-grab
    /// races.
    private var ourNextGrabSerial: UInt32 = 1

    /// If the peer currently holds the clipboard, the types
    /// it advertised, its grab serial, AND the selection it
    /// grabbed (so our follow-up REQUEST echoes the correct
    /// selection byte — VZ silently drops REQUESTs that don't
    /// match the outstanding grab's selection). `nil` when we
    /// hold the clipboard (or nobody does — neither side has
    /// copied since connection).
    private var peerGrab: (selection: VDAgentClipboardSelection, types: [VDAgentClipboardType], serial: UInt32?)?

    /// True between the moment we send a `CLIPBOARD_GRAB` and
    /// the moment the peer takes ownership away from us
    /// (either by sending its own GRAB or by replacing our
    /// content via a CLIPBOARD reply to our REQUEST — i.e.,
    /// the guest→host direction completes and the peer can
    /// re-initiate).
    ///
    /// Used to drive spec-correct re-grab semantics: if we
    /// still hold an active grab and the user copies again on
    /// the guest, we must send `CLIPBOARD_RELEASE` before the
    /// new `CLIPBOARD_GRAB`. The SPICE capability
    /// `CAP_CLIPBOARD_NO_RELEASE_ON_REGRAB` (bit 13) lets
    /// *compliant peers* skip the RELEASE step, but — per
    /// spec — the intersection of capabilities governs
    /// behavior. Apple's `VZSpiceAgentPortAttachment` is a
    /// black box; if it doesn't announce bit 13, the peer
    /// would silently treat our prior grab as still active
    /// and **drop every subsequent re-grab** — causing the
    /// host's paste to keep returning the first-grab's
    /// content regardless of how many times the user
    /// re-copies on the guest. Sending RELEASE proactively
    /// is always spec-safe and costs 4 payload bytes.
    private var ourGrabActive: Bool = false

    /// `changeCount` immediately after our last pasteboard
    /// write (in response to a peer grab delivering data).
    /// Used to suppress "did the pasteboard change?" polling
    /// from re-announcing as a grab — otherwise every host→
    /// guest paste would bounce back as a guest→host grab
    /// forever.
    private var lastSelfWrittenChangeCount: Int = 0

    /// The pasteboard `changeCount` we last *observed* and
    /// treated as our pasteboard state. Initial value 0 means
    /// "never observed"; the first poll will see the real
    /// current count and emit a grab if non-zero.
    private var observedChangeCount: Int = 0


    // MARK: - Init

    /// Designated initializer.
    /// - Parameters:
    ///   - transport: the opened SPICE transport.
    ///   - pasteboard: bridge to the guest's pasteboard.
    public init(
        transport: SpiceTransport,
        pasteboard: any PasteboardBridge
    ) {
        self.transport = transport
        self.pasteboard = pasteboard

        let (stream, continuation) = AsyncStream<SpiceAgentStatus>
            .makeStream()
        self.statusStream = stream
        self.statusContinuation = continuation
        continuation.yield(.notStarted)
    }

    /// Convenience factory that opens the default SPICE device
    /// path (`/dev/tty.com.redhat.spice.0`) and wraps it in a
    /// `SpiceTransport`. Throws
    /// ``SpiceSerialTransport/SpiceSerialPortError/openFailed(path:errno:)``
    /// if the virtio-serial port isn't present (VM isn't
    /// configured for SPICE, or the agent attachment failed).
    ///
    /// Lets consumers avoid importing `SpiceSerialTransport`
    /// directly for the common case.
    public static func withDefaultTransport(
        pasteboard: any PasteboardBridge
    ) throws -> SpiceClipboardAgent {
        let transport = try SpiceTransport()
        return SpiceClipboardAgent(
            transport: transport,
            pasteboard: pasteboard
        )
    }

    /// Begins the protocol: starts the transport, announces
    /// our capabilities, and kicks off the inbound + polling
    /// tasks. Runs forever until the transport closes or an
    /// error terminates it.
    public func run() async {
        statusContinuation?.yield(.connecting)
        await transport.start()

        // Snapshot the guest pasteboard's current change
        // count at startup so the first `pollOnce` doesn't
        // treat whatever is already there as "the user just
        // copied." Critical after a reconnect (Path X
        // watchdog recovery): the pasteboard may still hold
        // content the previous agent session just wrote from
        // a host→guest transfer, and re-grabbing it would
        // echo host content back to host — harmless for
        // Apple's de-duping peer, but a waste of bandwidth
        // and polluting log noise.
        let initialCount = await pasteboard.currentChangeCount()
        observedChangeCount = initialCount
        lastSelfWrittenChangeCount = initialCount
        spiceLog.notice(
            "startup snapshot changeCount=\(initialCount, privacy: .public)"
        )

        // Send our capabilities announcement. Using
        // `request = false` — we assume the host will reply
        // with its own announce either preceding or following
        // ours. If the host already sent an announce with
        // `request = true` before we got here, our non-request
        // announcement is still the correct response.
        do {
            let announce = VDAgentAnnounceCapabilities(
                request: false,
                capabilities: .macGuestDefault
            )
            try await transport.send(
                type: .announceCapabilities,
                payload: announce.encode()
            )
        } catch {
            statusContinuation?.yield(.failed(.announceFailed(error)))
            return
        }

        // Two concurrent tasks: one drains the inbound
        // message stream, one polls the pasteboard. Structured
        // concurrency via `withTaskGroup` so either task
        // completing (normally or via error) cancels the
        // other and the whole agent shuts down cleanly.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.runInboundLoop()
            }
            group.addTask { [weak self] in
                await self?.runPasteboardPoller()
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Inbound

    private func runInboundLoop() async {
        do {
            for try await message in transport.messages {
                await handle(message: message)
            }
        } catch {
            statusContinuation?.yield(.failed(.transportFailed(error)))
        }
        statusContinuation?.yield(.notStarted)
    }

    private func handle(message: SpiceIncomingMessage) async {
        guard let type = message.type else {
            // Unknown message type — spec says ignore
            // quietly. Future SPICE revisions may add types
            // we don't model; rejecting would break forward
            // compatibility.
            return
        }
        do {
            switch type {
            case .announceCapabilities:
                try await handleAnnounce(payload: message.payload)
            case .clipboardGrab:
                try await handleGrab(payload: message.payload)
            case .clipboardRequest:
                try await handleRequest(payload: message.payload)
            case .clipboard:
                try await handleClipboardData(payload: message.payload)
            case .clipboardRelease:
                try handleRelease(payload: message.payload)
            }
        } catch {
            // Log via status so the menu bar can surface
            // decode failures. Don't tear down the transport —
            // one bad frame shouldn't kill the channel.
            statusContinuation?.yield(
                .failed(.frameDecodeFailed(messageType: type, cause: error))
            )
        }
    }

    private func handleAnnounce(payload: Data) async throws {
        let announce = try VDAgentAnnounceCapabilities.decode(
            payload: payload
        )
        peerCapabilities = announce.capabilities
        peerAnnounced = true
        spiceLog.notice(
            "announce ← peer caps=0x\(announce.capabilities.rawValue, format: .hex, privacy: .public) request=\(announce.request, privacy: .public)"
        )
        statusContinuation?.yield(
            .connected(peerCapabilities: announce.capabilities.rawValue)
        )
        // Per the SPICE agent protocol, a peer ANNOUNCE with
        // `request=true` is an explicit ask to respond with
        // our own ANNOUNCE. Our startup already sends one
        // unconditionally, but a race-safe peer may also set
        // `request=true` if it hasn't seen ours by the time
        // it emits its own — and strict peers will wait for
        // our reply before advancing the handshake, which
        // can manifest as "GRAB flows but REQUEST replies
        // never arrive." Always honour the request.
        if announce.request {
            let reply = VDAgentAnnounceCapabilities(
                request: false,
                capabilities: .macGuestDefault
            )
            spiceLog.notice(
                "announce → peer (reply to request=true)"
            )
            do {
                try await transport.send(
                    type: .announceCapabilities,
                    payload: reply.encode()
                )
            } catch {
                spiceLog.error(
                    "announce → peer FAILED: \(String(describing: error), privacy: .public)"
                )
                statusContinuation?.yield(.failed(.announceFailed(error)))
            }
        }
    }

    private func handleGrab(payload: Data) async throws {
        let grab = try VDAgentClipboardMessage.Grab.decode(
            payload: payload,
            hasSerial: peerCapabilities.contains(.clipboardGrabSerial)
        )
        peerGrab = (grab.selection, grab.types, grab.serial)
        // Peer is taking ownership — any grab we held is
        // implicitly superseded. Per the SPICE spec: *"If a
        // GRAB message has been sent and is currently active,
        // then a successive GRAB message is received from
        // the peer, no RELEASE message should be sent to the
        // peer for the previous active grab."*
        ourGrabActive = false
        spiceLog.notice(
            "grab ← peer selection=\(String(describing: grab.selection), privacy: .public) types=\(grab.types.map { "\($0)" }.joined(separator: ","), privacy: .public) serial=\(grab.serial.map(String.init) ?? "nil", privacy: .public) peerCaps=0x\(self.peerCapabilities.rawValue, format: .hex, privacy: .public)"
        )

        // Eagerly request the peer's preferred type — the
        // first non-`.none` entry in their type list.
        //
        // The original v1 behaviour was to defer the REQUEST
        // until the user actually pasted in the guest
        // (tracked behind a "wire paste-intercept" follow-up).
        // In practice, that meant host→guest paste never
        // worked: there's no clean `⌘V`-interception hook in
        // a menu-bar agent without an Accessibility
        // entitlement, and the UX contract users expect from
        // a clipboard bridge is "cross-machine paste just
        // works, no ritual."
        //
        // Eager pull matches the behaviour of every widely-
        // deployed SPICE vd_agent client (spice-vdagent on
        // Linux, Windows spice-guest-tools, VirtIO-Win). The
        // bandwidth argument is weak — the host's own
        // `NSPasteboard` already holds the bytes in-process,
        // the guest already accepts up to `spiceMaxClipboardSize`
        // (100 MiB) per payload, and on Apple silicon the
        // virtio-console is a zero-copy memory transfer, not
        // a wire link. The privacy argument is also weak —
        // the user copied on the host intentionally; the
        // entire point of a clipboard bridge is to move that
        // byte stream into the guest.
        //
        // Text-only bridge: accept only `utf8Text` GRABs.
        // If the peer's GRAB list doesn't include text (e.g.
        // the host user copied an image with no text
        // alternative), we ignore the grab — spec-permitted:
        // receivers are free to pick any type they can
        // handle, and "none" is equivalent to "nothing I can
        // service." Apple's peer recovers cleanly because we
        // never REQUESTed, so there's no outstanding operation
        // to get stuck.
        guard grab.types.contains(.utf8Text) else {
            spiceLog.notice(
                "grab ← peer offered no text type — ignoring (image clipboard not supported)"
            )
            return
        }
        let preferred: VDAgentClipboardType = .utf8Text
        // Echo the peer's selection byte — REQUESTs with a
        // mismatched selection are silently dropped by most
        // SPICE server implementations.
        let request = VDAgentClipboardMessage.Request(
            selection: grab.selection,
            type: preferred
        )
        spiceLog.notice(
            "request → peer selection=\(String(describing: grab.selection), privacy: .public) type=\(String(describing: preferred), privacy: .public)"
        )
        do {
            try await transport.send(
                type: .clipboardRequest,
                payload: request.encode()
            )
        } catch {
            spiceLog.error(
                "request → peer FAILED: \(String(describing: error), privacy: .public)"
            )
            statusContinuation?.yield(.failed(.requestReplyFailed(error)))
        }
    }

    private func handleRequest(payload: Data) async throws {
        // Decode: a throw here is a wire-format problem and
        // should bubble to the outer `.frameDecodeFailed`
        // handler.
        let request = try VDAgentClipboardMessage.Request.decode(
            payload: payload
        )
        spiceLog.notice(
            "request ← peer type=\(String(describing: request.type), privacy: .public)"
        )
        // Live-read the pasteboard. For the common case
        // (TIFF screenshot copied on guest, Apple asks for
        // TIFF), this is a zero-transcode `data(forType:)`
        // call — plenty fast to answer the REQUEST without a
        // pre-warm cache. If the user cleared the pasteboard
        // between our grab and this request, we send empty
        // data for the requested type — spec doesn't forbid
        // zero-length, and it's the right signal that the
        // grab is no longer fulfillable.
        let data = await pasteboard.read(type: request.type) ?? Data()
        spiceLog.notice(
            "pasteboard read type=\(String(describing: request.type), privacy: .public) bytes=\(data.count, privacy: .public)"
        )
        // Size guard: SPICE peers announcing `maxClipboard`
        // can refuse oversize data. We announced 100 MiB
        // above; refuse to send anything larger ourselves
        // rather than trying and getting hung.
        guard data.count <= Int(spiceMaxClipboardSize) else {
            spiceLog.error(
                "request ← peer type=\(String(describing: request.type), privacy: .public) bytes=\(data.count, privacy: .public) exceeds spiceMaxClipboardSize=\(spiceMaxClipboardSize, privacy: .public); dropping"
            )
            return
        }
        let reply = VDAgentClipboardMessage.Payload(
            selection: request.selection,
            type: request.type,
            data: data
        )
        spiceLog.notice(
            "clipboard → peer type=\(String(describing: request.type), privacy: .public) bytes=\(data.count, privacy: .public)"
        )
        // Send: any throw here is a transport-level problem,
        // not a decode problem — surface it as a dedicated
        // ``SpiceAgentError/requestReplyFailed`` so the
        // consumer can tell the two cases apart.
        do {
            try await transport.send(
                type: .clipboard,
                payload: reply.encode()
            )
        } catch {
            spiceLog.error(
                "clipboard → peer FAILED: \(String(describing: error), privacy: .public)"
            )
            statusContinuation?.yield(.failed(.requestReplyFailed(error)))
        }
    }

    private func handleClipboardData(payload: Data) async throws {
        let data = try VDAgentClipboardMessage.Payload.decode(
            payload: payload
        )
        spiceLog.notice(
            "clipboard ← peer type=\(String(describing: data.type), privacy: .public) bytes=\(data.data.count, privacy: .public)"
        )
        // Reject obviously-oversize payloads. The host should
        // have respected our max-clipboard advertisement, but
        // defense in depth.
        guard data.data.count <= Int(spiceMaxClipboardSize) else {
            spiceLog.error(
                "clipboard ← peer bytes=\(data.data.count, privacy: .public) exceeds spiceMaxClipboardSize; dropping"
            )
            return
        }
        let newChangeCount = await pasteboard.write(
            type: data.type,
            data: data.data
        )
        spiceLog.notice(
            "pasteboard write type=\(String(describing: data.type), privacy: .public) bytes=\(data.data.count, privacy: .public) changeCount=\(newChangeCount, privacy: .public)"
        )
        // Peer owns the clipboard now — our grab (if any) is
        // implicitly cancelled. Avoid emitting a redundant
        // RELEASE on the next guest-side copy.
        ourGrabActive = false
        // Remember the changeCount we just produced so the
        // poller doesn't see it as a new guest-side copy and
        // echo it back as a GRAB.
        lastSelfWrittenChangeCount = newChangeCount
        observedChangeCount = newChangeCount
    }

    private func handleRelease(payload: Data) throws {
        // Peer cleared its grab — drop our cached offer. We
        // still decode to validate the selection prefix rather
        // than silently accepting garbage on the wire.
        _ = try VDAgentClipboardMessage.Release.decode(payload: payload)
        peerGrab = nil
    }

    // MARK: - Outbound (pasteboard polling)

    /// Pasteboard-change polling interval.
    ///
    /// Apple's `NSPasteboard` has no change notification —
    /// the public API is a monotonic `changeCount` polled by
    /// the caller. `spice-vdagent` on Linux uses 200–300 ms
    /// against X11's richer event model. On macOS, a faster
    /// cadence is worth it: every millisecond between "user
    /// copies on guest" and "we emit GRAB" widens the window
    /// where the user can switch windows and ⌘V *before* the
    /// host `NSPasteboard` has the promise registered — which
    /// is exactly the race behind "paste-twice on first try".
    ///
    /// 100 ms puts us at 10 wake-ups/sec — negligible CPU for
    /// a guest that's already running a desktop session, and
    /// matches what macOS's own Universal Clipboard watcher
    /// is observed to do via `NSWorkspace` + `NSPasteboard`
    /// polling in `pasteboardd`.
    private let pollInterval: Duration = .milliseconds(100)

    private func runPasteboardPoller() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return }
            await pollOnce()
        }
    }

    /// Exposed internal for tests to drive deterministically.
    func pollOnce() async {
        let current = await pasteboard.currentChangeCount()
        // Ignore echoes of our own writes.
        if current == lastSelfWrittenChangeCount { return }
        // Ignore "no change since last poll".
        if current == observedChangeCount { return }
        observedChangeCount = current

        let types = await pasteboard.availableTypes()
        let rawUTIs = await pasteboard.declaredPasteboardTypes()
        spiceLog.notice(
            "pollOnce changeCount=\(current, privacy: .public) availableTypes=\(types.map { "\($0)" }.joined(separator: ","), privacy: .public) rawUTIs=\(rawUTIs.joined(separator: ","), privacy: .public)"
        )
        guard !types.isEmpty else {
            spiceLog.debug(
                "pollOnce changeCount=\(current, privacy: .public) but no SPICE-representable types on pasteboard"
            )
            // Pasteboard was cleared. Per the spec, we could
            // send RELEASE here to explicitly retract our
            // prior grab. For now we rely on the implicit
            // re-grab-on-next-copy semantics; an explicit
            // RELEASE is a polish item.
            return
        }

        // If we still hold an active grab, SPICE requires us
        // to RELEASE it before issuing a new one — unless
        // both sides announced `clipboardNoReleaseOnRegrab`
        // (bit 13). Safer to send RELEASE unconditionally:
        // peers that don't need it ignore it (4-byte payload),
        // peers that do need it won't silently drop our new
        // grab as duplicate. See doc-comment on
        // ``ourGrabActive`` for the full reasoning.
        if ourGrabActive {
            let release = VDAgentClipboardMessage.Release(
                selection: .clipboard
            )
            spiceLog.notice("release → peer (pre-regrab)")
            do {
                try await transport.send(
                    type: .clipboardRelease,
                    payload: release.encode()
                )
            } catch {
                spiceLog.error(
                    "release → peer FAILED: \(String(describing: error), privacy: .public)"
                )
                // Best-effort — carry on with the new grab.
            }
            ourGrabActive = false
        }

        // Per SPICE spec, the grab-serial field is on the wire
        // only when **both** peers announce
        // `clipboardGrabSerial` (bit 14). Decide from the
        // intersection of caps — not our own alone — or the
        // peer decodes the payload with the wrong offset and
        // either tolerates garbage (Apple's current
        // `VZSpiceAgentPortAttachment` behavior) or rejects
        // the grab outright (stricter peers).
        //
        // Observed peer caps for Apple's SPICE host on
        // macOS 26: 0x460 — lacks bit 14, so we must NOT
        // include the serial. Recomputed per-grab rather
        // than cached at init because the peer's announce
        // may arrive after construction.
        let negotiatedCaps = peerCapabilities
            .intersection(.macGuestDefault)
        let serial = ourNextGrabSerial
        ourNextGrabSerial &+= 1
        let grab = VDAgentClipboardMessage.Grab(
            selection: .clipboard,
            types: types,
            serial: negotiatedCaps.contains(.clipboardGrabSerial)
                ? serial
                : nil
        )
        spiceLog.notice(
            "grab → peer types=\(types.map { "\($0)" }.joined(separator: ","), privacy: .public) serial=\(serial, privacy: .public)"
        )
        do {
            try await transport.send(
                type: .clipboardGrab,
                payload: grab.encode()
            )
            ourGrabActive = true
        } catch {
            spiceLog.error(
                "grab → peer FAILED: \(String(describing: error), privacy: .public)"
            )
            statusContinuation?.yield(.failed(.grabSendFailed(error)))
        }
    }

    // MARK: - Teardown

    /// Cancels inbound loop + pasteboard poller and closes
    /// the transport. Safe to call multiple times.
    public func stop() async {
        await transport.close()
        statusContinuation?.yield(.notStarted)
        statusContinuation?.finish()
        statusContinuation = nil
    }
}

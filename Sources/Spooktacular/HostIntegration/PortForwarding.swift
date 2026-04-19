import SwiftUI
import os
import SpooktacularKit

/// Detects and surfaces ports the guest agent reports as
/// listening, so the user can jump from the workspace window
/// directly to, say, a dev server running inside the VM.
///
/// This is GhostVM's port-forwarding auto-detection pared down
/// to its essential UX: a small glass panel lists discovered
/// ports with owning process names; clicking a port copies
/// `http://<guest-ip>:<port>` to the clipboard and offers to
/// open it in the default browser. We deliberately don't
/// spawn external processes (no `socat`) — the guest already
/// has a reachable IP via NAT or bridged mode.
@MainActor
@Observable
final class PortForwardingMonitor {

    /// Ports the guest has reported as listening on the most
    /// recent poll.
    var ports: [GuestPortInfo] = []

    /// Resolved guest IP — `nil` while the agent hasn't returned
    /// one yet, or when NAT is in a transient state.
    var guestIP: String?

    /// Whether the last poll succeeded. Drives the toolbar chip's
    /// "connected" vs "checking" icon.
    var connected: Bool = false

    private let logger = Logger(subsystem: "com.spooktacular.app", category: "ports")
    private var pollTask: Task<Void, Never>?

    /// How often to refresh the listening-port list. 5 s matches
    /// GhostVM's observed cadence.
    static let pollInterval: Duration = .seconds(5)

    /// Starts the polling loop for a workspace. Safe to call
    /// multiple times — re-starting cancels the previous loop.
    func start(client: GuestAgentClient, macAddress: MACAddress?) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(client: client, macAddress: macAddress)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Stops the polling loop.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        ports = []
        guestIP = nil
        connected = false
    }

    // MARK: - Tick

    private func tick(client: GuestAgentClient, macAddress: MACAddress?) async {
        do {
            let discovered = try await client.listeningPorts()
            ports = discovered.sorted { $0.port < $1.port }
            connected = true

            if guestIP == nil, let mac = macAddress {
                // One-shot IP resolution — cached for the rest of
                // this workspace session. `resolveIP` can be slow
                // (ARP scan), so we deliberately do it only once.
                guestIP = try await IPResolver.resolveIP(macAddress: mac)
            }
        } catch {
            connected = false
            logger.debug("listeningPorts failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Port panel

/// Glass popover that lists discovered ports with copy and "open
/// in browser" buttons per row. Bound to a
/// ``PortForwardingMonitor``; renders an empty state when no
/// ports are detected.
struct PortPanel: View {

    let monitor: PortForwardingMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            subtitle
            Divider()
            content
        }
        .frame(width: 360, height: 360)
    }

    private var header: some View {
        HStack {
            Label("Listening ports", systemImage: "network")
                .font(.headline)
            Spacer()
            Image(systemName: monitor.connected ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
                .foregroundStyle(monitor.connected ? .green : .orange)
                // Subtle pulse on the live connection indicator —
                // reinforces "yes, this is real-time data" without
                // adding chrome. Apple's `.symbolEffect(.pulse)`
                // honours the user's Reduce Motion preference
                // automatically. Docs:
                // https://developer.apple.com/documentation/swiftui/view/symboleffect(_:options:value:)
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    value: monitor.connected
                )
                .help(monitor.connected ? "Guest agent is responding" : "Waiting for guest agent")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    /// Expectation-setting: this list only shows services inside
    /// the guest that are accepting *incoming* connections (SSH,
    /// a dev server, `python -m http.server`, etc.). Safari,
    /// Chrome, and other browser activity is *outbound* only and
    /// won't appear here. Without this caption new users
    /// routinely ask "why isn't Safari in the list?" — now the
    /// UI answers the question before it's asked.
    private var subtitle: some View {
        Text("Services inside the workspace that accept incoming connections. Click a row to copy the URL. Outbound traffic (Safari, Chrome, git pull, …) isn't listed — only listeners.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        if monitor.ports.isEmpty {
            ContentUnavailableView {
                Label("No listening services", systemImage: "network.slash")
            } description: {
                Text("Start an SSH daemon, a dev server, or any tool that binds a port and it will appear here automatically.")
            }
        } else {
            List(monitor.ports, id: \.port) { info in
                PortRow(info: info, guestIP: monitor.guestIP)
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Row

/// Single listening-port row. Copies `http://<ip>:<port>` on click
/// and opens in the default browser on right-click.
struct PortRow: View {
    let info: GuestPortInfo
    let guestIP: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(info.port)")
                    .font(.system(.body, design: .monospaced).weight(.medium))
                Text(info.processName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                openInBrowser()
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .disabled(guestIP == nil)
            .help(guestIP.map { "Open http://\($0):\(info.port)" } ?? "Waiting for guest IP")

            Button {
                copyURL()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(guestIP == nil)
            .help("Copy URL")
        }
        .padding(.vertical, 2)
    }

    private var url: URL? {
        guard let ip = guestIP else { return nil }
        return URL(string: "http://\(ip):\(info.port)")
    }

    @MainActor
    private func openInBrowser() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func copyURL() {
        guard let url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }
}

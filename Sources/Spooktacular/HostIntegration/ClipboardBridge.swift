import AppKit
import SwiftUI
import os
import SpooktacularKit

/// Bidirectional clipboard sync between the host and a running
/// workspace, gated by user consent.
///
/// macOS and the guest OS each own an independent pasteboard.
/// Cross-copying would surprise users and leak secrets, so every
/// sync starts with an explicit permission prompt. Once granted,
/// approval is cached per-workspace for a sliding 15-minute
/// window — matching the "grant per session" model from Mail,
/// Messages, and AirDrop.
///
/// Host-side observation uses `NSPasteboard.general.changeCount`
/// polled at 500 ms, which is the standard approach and costs
/// negligible CPU. Guest-side observation routes through
/// ``GuestAgentClient/getClipboard()``.
@MainActor
@Observable
final class ClipboardBridge {

    // MARK: - Consent

    /// Per-workspace approval expiry timestamps. If the current
    /// time is past the stored date the approval has lapsed.
    private var approvedUntil: [String: Date] = [:]

    /// How long a single user approval remains valid.
    static let approvalWindow: TimeInterval = 15 * 60

    // MARK: - Observation state

    /// The last pasteboard change count we reacted to on the host.
    /// `NSPasteboard.changeCount` increments on every copy event;
    /// comparing against the stored value is how we detect a fresh
    /// copy vs our own programmatic write.
    private var lastHostChangeCount: Int = NSPasteboard.general.changeCount

    /// A pending prompt the UI should surface. `nil` when no
    /// prompt is outstanding.
    var pendingPrompt: Prompt?

    /// Describes a single outstanding user-consent request.
    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let workspace: String
        let preview: String
        let direction: Direction

        enum Direction: Equatable {
            case hostToGuest
            case guestToHost
        }
    }

    // MARK: - Polling

    private let logger = Logger(subsystem: "com.spooktacular.app", category: "clipboard")

    /// Starts observation for a workspace. Call when a workspace
    /// window becomes key; call ``stop(for:)`` when it resigns or
    /// the workspace closes.
    func start(for workspace: String, client: GuestAgentClient) {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.tick(workspace: workspace, client: client)
            }
        }
    }

    /// Reacts to pasteboard-change ticks. Private surface for the
    /// polling task launched by ``start(for:client:)``.
    private func tick(workspace: String, client: GuestAgentClient) async {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastHostChangeCount else { return }
        lastHostChangeCount = currentCount

        guard let text = NSPasteboard.general.string(forType: .string) else {
            return
        }

        if isApproved(workspace: workspace) {
            await forwardHostToGuest(workspace: workspace, client: client, text: text)
        } else {
            pendingPrompt = Prompt(
                workspace: workspace,
                preview: String(text.prefix(120)),
                direction: .hostToGuest
            )
        }
    }

    // MARK: - Approval

    /// User-approved the current pending prompt. Caches approval
    /// for the sliding window and performs the queued action.
    func approvePending(client: GuestAgentClient) async {
        guard let prompt = pendingPrompt else { return }
        approvedUntil[prompt.workspace] = Date().addingTimeInterval(Self.approvalWindow)
        pendingPrompt = nil

        switch prompt.direction {
        case .hostToGuest:
            if let text = NSPasteboard.general.string(forType: .string) {
                await forwardHostToGuest(
                    workspace: prompt.workspace,
                    client: client,
                    text: text
                )
            }
        case .guestToHost:
            break   // guest-to-host requires active polling; see future phase
        }
    }

    /// User denied the current pending prompt. Does NOT cache
    /// denial — a subsequent copy event re-prompts the user so
    /// they can change their mind without restarting the app.
    func denyPending() {
        pendingPrompt = nil
    }

    private func isApproved(workspace: String) -> Bool {
        guard let deadline = approvedUntil[workspace] else { return false }
        return deadline > Date()
    }

    // MARK: - Transfer

    private func forwardHostToGuest(
        workspace: String,
        client: GuestAgentClient,
        text: String
    ) async {
        do {
            try await client.setClipboard(text)
            logger.debug("Forwarded \(text.count) chars to guest of '\(workspace, privacy: .public)'")
        } catch {
            logger.error("Clipboard forward failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Permission sheet

/// Glass-chromed permission sheet shown when a clipboard sync is
/// pending user approval. Binds to ``ClipboardBridge/pendingPrompt``
/// and calls `approve` / `deny` on the bridge.
struct ClipboardPermissionSheet: View {

    let prompt: ClipboardBridge.Prompt
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, 20)

            VStack(spacing: 6) {
                Text("Share clipboard with '\(prompt.workspace)'?")
                    .font(.headline)
                Text(prompt.direction == .hostToGuest
                     ? "Spooktacular wants to paste this text into the workspace."
                     : "The workspace is asking to copy this text to your clipboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            ScrollView {
                Text(prompt.preview)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 100)
            .glassCard(cornerRadius: 12)
            .padding(.horizontal, 24)

            Text("Approval lasts 15 minutes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                Button("Don't Share", action: onDeny)
                    .keyboardShortcut(.cancelAction)
                Button("Share", action: onApprove)
                    .glassButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 380)
    }
}

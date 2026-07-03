import Foundation
import UserNotifications
import os

/// Posts macOS notifications on VM lifecycle transitions so users
/// see "workspace started" / "stopped" / "failed" toasts without
/// staring at the app.
///
/// The first call triggers a one-time permission request. All
/// subsequent posts are best-effort: a denied authorization is
/// logged but does not propagate — losing a notification is never
/// worth interrupting a VM boot.
@MainActor
final class VMNotifications {

    private let logger = Logger(subsystem: "com.spooktacular.app", category: "notifications")
    private var didRequestAuthorization: Bool = false

    /// Post a "workspace started" notification.
    ///
    /// - Parameters:
    ///   - key: The VM's stable `vms` dictionary key (bundle
    ///     UUID string) — used only for the notification
    ///     identifier, never shown to the user. Display names
    ///     aren't guaranteed unique, so the identifier must stay
    ///     keyed by something that is.
    ///   - displayName: The user-facing label shown as the
    ///     notification's title.
    func notifyStarted(_ key: String, displayName: String) {
        post(
            identifier: "started-\(key)",
            title: displayName,
            body: "Workspace is running.",
            category: .info
        )
    }

    /// Post a "workspace stopped" notification. See
    /// ``notifyStarted(_:displayName:)`` for the parameter split.
    func notifyStopped(_ key: String, displayName: String) {
        post(
            identifier: "stopped-\(key)",
            title: displayName,
            body: "Workspace stopped.",
            category: .info
        )
    }

    /// Post a "workspace failed" notification with the error
    /// text. See ``notifyStarted(_:displayName:)`` for the
    /// parameter split.
    func notifyFailed(_ key: String, displayName: String, error: String) {
        post(
            identifier: "failed-\(key)",
            title: "\(displayName) failed",
            body: error,
            category: .critical
        )
    }

    // MARK: - Private

    private enum Category {
        case info, critical
        var interruptionLevel: UNNotificationInterruptionLevel {
            self == .critical ? .timeSensitive : .active
        }
    }

    private func post(identifier: String, title: String, body: String, category: Category) {
        Task { [weak self] in
            await self?.ensureAuthorization()
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.interruptionLevel = category.interruptionLevel
            content.sound = category == .critical ? .defaultCritical : .default

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil   // deliver immediately
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                self?.log(error: error)
            }
        }
    }

    private func ensureAuthorization() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            if !granted {
                logger.info("User declined notification authorization")
            }
        } catch {
            logger.error("Notification authorization error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func log(error: Error) {
        logger.error("Notification post failed: \(error.localizedDescription, privacy: .public)")
    }
}

// Desktop notifications for OSC 9/777 (GHOSTTY_ACTION_DESKTOP_NOTIFICATION) and the `notify` control
// command. Sent as a GNotification through the GApplication so a click routes back to the app's
// `reveal` action (click-to-reveal the firing session); falls back to notify-send if the app handle
// isn't up yet. Action routing requires the installed `.desktop` (shipped by install-linux.sh); the
// banner itself shows either way.
import CGtk
import Foundation
import agtermCore

enum NotificationManager {
    /// Whether OS banners are enabled (the user's `notificationsEnabled` setting, default on). The
    /// unseen badge tracks regardless — this gates only the banner, mirroring macOS `bannersEnabled`.
    static var bannersEnabled: Bool { SettingsStore().load().notificationsEnabled ?? true }

    /// Post a banner. When `target` or `sessionID` is set, attach a default action so clicking the banner
    /// reveals the session/pane (`target` is the pane-qualified notification identity).
    @MainActor static func send(title: String, body: String, sessionID: UUID? = nil, target: String? = nil) {
        guard let app = gApp else { sendViaNotifySend(title: title, body: body); return }
        let n = g_notification_new(title.isEmpty ? "agterm" : title)
        body.withCString { g_notification_set_body(n, $0) }
        let actionTarget = target ?? sessionID?.uuidString
        if let actionTarget {
            let variant = g_variant_new_string(actionTarget)   // floating; set_..._value sinks it
            "app.reveal".withCString { g_notification_set_default_action_and_target_value(n, $0, variant) }
        }
        // Per-session id so a session's repeated notifications COALESCE (replace), while different
        // sessions stack — the GNotification replaces-id behavior.
        let notifID = sessionID.map { "agterm-\($0.uuidString)" } ?? "agterm-notify"
        notifID.withCString { g_application_send_notification(GAPP(app), $0, n) }
        g_object_unref(n.map { UnsafeMutableRawPointer($0) })
    }

    /// Withdraw a session's delivered banner (called on select) so it doesn't linger in the notification
    /// center after the user has seen the session — the libnotify analogue of macOS's removeDelivered.
    /// Uses the SAME per-session id `send` publishes under.
    @MainActor static func withdraw(sessionID: UUID) {
        guard let app = gApp else { return }
        "agterm-\(sessionID.uuidString)".withCString { g_application_withdraw_notification(GAPP(app), $0) }
    }

    private static func sendViaNotifySend(title: String, body: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/notify-send")
        // `--` terminates option parsing so a title/body starting with `-` (these come from untrusted
        // OSC 9/777 sequences and the control socket) can't smuggle flags.
        proc.arguments = ["-a", "agterm", "--", title.isEmpty ? "agterm" : title, body]
        try? proc.run()
    }
}

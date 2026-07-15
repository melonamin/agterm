import Foundation
import agtermCore

struct NotificationDelivery: Sendable, Equatable {
    let title: String
    let body: String
    let identity: String
}

struct TerminalNotificationRecord: Sendable, Equatable {
    let sessionID: UUID
    let windowID: UUID
    let pane: PaneRole
    let title: String
    let body: String
    let firingIsFocused: Bool
    let appActive: Bool
}

extension AppStore {
    @discardableResult
    func recordTerminalNotification(_ record: TerminalNotificationRecord) -> NotificationDelivery? {
        guard let session = session(withID: record.sessionID) else { return nil }
        session.unseenCount += 1
        guard TerminalNotification.shouldDeliver(
            firingIsFocused: record.firingIsFocused,
            appActive: record.appActive
        ) else { return nil }
        return NotificationDelivery(
            title: record.title,
            body: record.body,
            identity: TerminalNotification.identity(
                windowID: record.windowID,
                sessionID: record.sessionID,
                pane: record.pane
            )
        )
    }
}

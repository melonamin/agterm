import Foundation
import agtermCore

extension AppStore {
    func setPaneFocus(_ toSplit: Bool, forSession sessionID: UUID) {
        guard let session = session(withID: sessionID), session.hasSplit else { return }
        if session.splitFocused != toSplit { session.splitFocused = toSplit }
    }

    func recordPwd(_ pwd: String, forSession sessionID: UUID, isSplit: Bool) {
        guard let session = session(withID: sessionID) else { return }
        if isSplit {
            if session.splitCwd != pwd { session.splitCwd = pwd }
        } else if session.currentCwd != pwd {
            session.currentCwd = pwd
        }
    }

    func recordTitle(_ title: String, forSession sessionID: UUID, isSplit: Bool) {
        guard let session = session(withID: sessionID) else { return }
        if isSplit {
            if session.splitTitle != title { session.splitTitle = title }
        } else if session.oscTitle != title {
            session.oscTitle = title
        }
    }
}

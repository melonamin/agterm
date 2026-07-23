import Foundation
import agtermCore

extension AppStore {
    func setPaneFocus(_ toSplit: Bool, forSession sessionID: UUID) {
        guard let session = session(withID: sessionID), session.hasSplit else { return }
        if session.splitFocused != toSplit { session.splitFocused = toSplit }
    }

    @discardableResult
    func recordPwd(_ pwd: String, forSession sessionID: UUID, isSplit: Bool) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        if isSplit {
            guard session.splitCwd != pwd else { return false }
            session.splitCwd = pwd
        } else if session.currentCwd != pwd {
            session.currentCwd = pwd
        } else {
            return false
        }
        return true
    }

    @discardableResult
    func recordTitle(_ title: String, forSession sessionID: UUID, isSplit: Bool) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        if isSplit {
            guard session.splitTitle != title else { return false }
            session.splitTitle = title
        } else if session.oscTitle != title {
            session.oscTitle = title
        } else {
            return false
        }
        return true
    }
}

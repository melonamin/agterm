import Foundation

extension AppStore {
    @discardableResult
    public func restoreRecentClosed(_ item: RecentClosedItem) -> Bool {
        switch item.kind {
        case .session:
            guard let recent = item.session else { return false }
            if restoreOrSelectExistingRecentSession(recent) { return true }
            let index: Int
            if let existing = workspaces.firstIndex(where: { $0.id == recent.workspaceID }) {
                index = existing
            } else {
                let insertAt = max(0, min(recent.workspaceIndex, workspaces.count))
                workspaces.insert(Workspace(id: recent.workspaceID, name: recent.workspaceName), at: insertAt)
                index = insertAt
            }
            let session = session(from: recent.snapshot)
            let insertAt = max(0, min(recent.sessionIndex, workspaces[index].sessions.count))
            workspaces[index].sessions.insert(session, at: insertAt)
            selectedSessionID = session.id
            autoUnfocusIfOutsideFocus(selectedSessionID)
            recordRecency()
            save()
            return true
        case .workspace:
            guard let recent = item.workspace else { return false }
            if restoreOrSelectExistingRecentWorkspace(recent) { return true }
            let workspace = workspace(from: recent.snapshot)
            // Persistent Open Recent appends like most editors' recent-project flow:
            // reopening brings the workspace back without reshuffling current workspaces.
            workspaces.append(workspace)
            selectedSessionID = recent.selectedSessionID.flatMap { sessionID in
                workspace.sessions.contains { $0.id == sessionID } ? sessionID : nil
            } ?? workspace.sessions.first?.id
            autoUnfocusIfOutsideFocus(selectedSessionID)
            recordRecency()
            save()
            return true
        }
    }

    private func restoreOrSelectExistingRecentSession(_ recent: RecentClosedSession) -> Bool {
        if let pendingID = pendingCloseID(containingSessionID: recent.snapshot.id) {
            return undoPendingClose(pendingID)
        }
        guard session(withID: recent.snapshot.id) != nil else { return false }
        selectSession(recent.snapshot.id)
        return true
    }

    private func restoreOrSelectExistingRecentWorkspace(_ recent: RecentClosedWorkspace) -> Bool {
        let sessionIDs = Set(recent.snapshot.sessions.map(\.id))
        if let pendingID = pendingCloseID(forWorkspaceID: recent.snapshot.id, sessionIDs: sessionIDs) {
            return undoPendingClose(pendingID)
        }
        if let existingWorkspace = workspaces.first(where: { $0.id == recent.snapshot.id }) {
            let target = recent.selectedSessionID.flatMap { id in
                existingWorkspace.sessions.contains { $0.id == id } ? id : nil
            } ?? existingWorkspace.sessions.first?.id
            if let target { selectSession(target) }
            return true
        }
        if let existingSession = workspaces.flatMap(\.sessions).first(where: { sessionIDs.contains($0.id) }) {
            selectSession(existingSession.id)
            return true
        }
        return false
    }

    private func pendingCloseID(containingSessionID sessionID: UUID) -> UUID? {
        for id in pendingCloseOrder.reversed() {
            guard let record = pendingCloseRecords[id] else { continue }
            switch record {
            case .session(let close) where close.session.id == sessionID:
                return id
            case .workspace(let close) where close.workspace.sessions.contains(where: { $0.id == sessionID }):
                return id
            default:
                continue
            }
        }
        return nil
    }

    private func pendingCloseID(forWorkspaceID workspaceID: UUID, sessionIDs: Set<UUID>) -> UUID? {
        for id in pendingCloseOrder.reversed() {
            guard let record = pendingCloseRecords[id] else { continue }
            switch record {
            case .workspace(let close)
                where close.workspace.id == workspaceID
                    || close.workspace.sessions.contains(where: { sessionIDs.contains($0.id) }):
                return id
            case .session(let close) where sessionIDs.contains(close.session.id):
                return id
            default:
                continue
            }
        }
        return nil
    }

    @discardableResult
    func recordRecentClosedSession(_ session: Session,
                                   workspaceID: UUID,
                                   workspaceName: String,
                                   workspaceIndex: Int,
                                   sessionIndex: Int,
                                   id: UUID = UUID()) -> UUID? {
        guard let recentClosedStore else { return nil }
        recentClosedStore.record(RecentClosedItem(
            id: id,
            kind: .session,
            title: session.displayName,
            subtitle: workspaceName,
            session: RecentClosedSession(workspaceID: workspaceID,
                                         workspaceName: workspaceName,
                                         workspaceIndex: workspaceIndex,
                                         sessionIndex: sessionIndex,
                                         snapshot: sessionSnapshot(session))
        ))
        recentClosedDidChange?()
        return id
    }

    @discardableResult
    func recordRecentClosedWorkspace(_ workspace: Workspace,
                                     selectedSessionID: UUID?,
                                     id: UUID = UUID()) -> UUID? {
        guard let recentClosedStore else { return nil }
        let sessionCount = workspace.sessions.count
        recentClosedStore.record(RecentClosedItem(
            id: id,
            kind: .workspace,
            title: workspace.name,
            subtitle: "\(sessionCount) session\(sessionCount == 1 ? "" : "s")",
            workspace: RecentClosedWorkspace(snapshot: workspaceSnapshot(workspace), selectedSessionID: selectedSessionID)
        ))
        recentClosedDidChange?()
        return id
    }

    func removeRecentClosedItem(_ id: UUID) {
        guard let recentClosedStore else { return }
        recentClosedStore.remove(id)
        recentClosedDidChange?()
    }
}

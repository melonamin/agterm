import Foundation

/// Host-free controller state for the sidebar's transient multi-selection.
///
/// `selectedSessionIDs` is ordered in the sidebar's visual/session order, not click order, so batch
/// operations are deterministic across tree and flagged modes. The active terminal selection remains
/// `AppStore.selectedSessionID`; this controller only tracks the broader set a contextual command should
/// operate on.
public struct SidebarSelectionController: Equatable, Sendable {
    public private(set) var selectedSessionIDs: [UUID] = []

    public init(selectedSessionIDs: [UUID] = []) {
        self.selectedSessionIDs = selectedSessionIDs
    }

    /// Replaces the transient sidebar selection with `ids`, filtered and ordered by `visibleSessionIDs`.
    public mutating func setSelection(_ ids: [UUID], visibleSessionIDs: [UUID]) {
        selectedSessionIDs = Self.normalized(ids, visibleSessionIDs: visibleSessionIDs)
    }

    /// Replaces the transient sidebar selection with the active session, or clears it when nil/hidden.
    public mutating func replace(with sessionID: UUID?, visibleSessionIDs: [UUID]) {
        guard let sessionID else {
            selectedSessionIDs = []
            return
        }
        setSelection([sessionID], visibleSessionIDs: visibleSessionIDs)
    }

    /// Removes ids no longer present in the model/visible projection.
    public mutating func prune(visibleSessionIDs: [UUID]) {
        setSelection(selectedSessionIDs, visibleSessionIDs: visibleSessionIDs)
    }

    /// Filters duplicate/unknown ids and returns them in the supplied visible order.
    public static func normalized(_ ids: [UUID], visibleSessionIDs: [UUID]) -> [UUID] {
        let requested = Set(ids)
        guard !requested.isEmpty else { return [] }
        return visibleSessionIDs.filter { requested.contains($0) }
    }
}

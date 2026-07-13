import Foundation
import Testing
@testable import agtermCore

@MainActor
final class MockControlActions: ControlActions {
    enum Call: Equatable {
        case tree(window: String?)
        case sessionNew(ControlSessionCreateOptions)
        case sessionSelect(target: String?, window: String?)
        case sessionGo(window: String?, SessionNavigation)
        case sessionClose(target: String?, window: String?)
        case sessionRename(target: String?, window: String?, String)
        case workspaceNew(window: String?, String?)
        case workspaceSelect(target: String?, window: String?)
        case workspaceRename(target: String?, window: String?, String)
        case workspaceDelete(target: String?, window: String?)
        case sessionMove(target: String?, window: String?, ControlSessionMove)
        case workspaceMove(target: String?, window: String?, ReorderDirection)
        case workspaceFocus(target: String?, window: String?, String?)
        case sessionFlag(target: String?, window: String?, String?)
        case sessionStatus(target: String?, window: String?, ControlSessionStatusUpdate)
        case sessionSplit(target: String?, window: String?, String?)
        case sessionScratch(target: String?, window: String?, String?, command: String?)
        case sessionFocus(target: String?, window: String?, String?)
        case sessionResize(target: String?, window: String?, ControlSplitResize)
        case font(target: String?, window: String?, String)
        case keymapReload
        case configReload
        case notify(target: String?, window: String?, title: String?, body: String)
        case themeSet(String?)
        case themeList
        case sidebarVisibility(ControlToggleMode)
        case sidebarViewMode(ControlSidebarViewMode)
        case expand(window: String?)
        case collapse(window: String?)
        case quick(String?)
        case sessionType(target: String?, window: String?, ControlSessionTypeOptions)
        case sessionCopy(target: String?, window: String?)
        case sessionSearch(target: String?, window: String?, text: String?, to: String?)
        case overlayOpen(target: String?, window: String?, ControlSessionOverlayOpenOptions)
        case overlayClose(target: String?, window: String?)
        case overlayResult(target: String?, window: String?)
        case sessionBackground(target: String?, window: String?, ControlSessionBackgroundOptions)
        case sessionText(target: String?, window: String?, ControlSessionTextOptions)
        case windowNew(String?)
        case windowList
        case windowSelect(target: String?)
        case windowClose(target: String?)
        case windowRename(target: String?, String)
        case windowDelete(target: String?)
        case windowResize(target: String?, width: Int, height: Int)
        case windowMove(target: String?, x: Int, y: Int, display: Int?)
        case windowZoom(target: String?)
        case restoreClear
    }

    var calls: [Call] = []
    var nextTreeResponse = ControlResponse(ok: false, error: "tree not stubbed")
    var nextSessionNewResponse = ControlResponse(ok: true)
    var nextSidebarVisibilityResponse = ControlResponse(ok: true)
    var nextSidebarViewModeResponse = ControlResponse(ok: true)
    var nextExpandResponse = ControlResponse(ok: true)
    var nextCollapseResponse = ControlResponse(ok: true)
    var nextFontResponse = ControlResponse(ok: true)
    var nextNotifyResponse = ControlResponse(ok: true)
    var nextKeymapResponse = ControlResponse(ok: true)
    var nextConfigResponse = ControlResponse(ok: true)
    var nextThemeSetResponse = ControlResponse(ok: true)
    var nextThemeListResponse = ControlResponse(ok: true)
    var nextQuickResponse = ControlResponse(ok: true)
    var nextSessionTypeResponse = ControlResponse(ok: true)
    var nextSessionCopyResponse = ControlResponse(ok: true)
    var nextSessionSearchResponse = ControlResponse(ok: true)
    var nextOverlayOpenResponse = ControlResponse(ok: true)
    var nextOverlayCloseResponse = ControlResponse(ok: true)
    var nextOverlayResultResponse = ControlResponse(ok: true)
    var nextSessionBackgroundResponse = ControlResponse(ok: true)
    var nextSessionTextResponse = ControlResponse(ok: true)
    var nextWindowNewResponse = ControlResponse(ok: true)
    var nextWindowListResponse = ControlResponse(ok: true)
    var nextWindowSelectResponse = ControlResponse(ok: true)
    var nextWindowCloseResponse = ControlResponse(ok: true)
    var nextWindowRenameResponse = ControlResponse(ok: true)
    var nextWindowDeleteResponse = ControlResponse(ok: true)
    var nextWindowResizeResponse = ControlResponse(ok: true)
    var nextWindowMoveResponse = ControlResponse(ok: true)
    var nextWindowZoomResponse = ControlResponse(ok: true)
    var nextRestoreClearResponse = ControlResponse(ok: true)

    func controlTree(window: String?) -> ControlResponse {
        calls.append(.tree(window: window))
        return nextTreeResponse
    }

    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse {
        calls.append(.sessionNew(options))
        return nextSessionNewResponse
    }

    func selectSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionSelect(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func goSession(window: String?, direction: SessionNavigation) -> ControlResponse {
        calls.append(.sessionGo(window: window, direction))
        return ControlResponse(ok: true)
    }

    func closeSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionClose(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse {
        calls.append(.sessionRename(target: target, window: window, name))
        return ControlResponse(ok: true)
    }

    func createWorkspace(window: String?, name: String?) -> ControlResponse {
        calls.append(.workspaceNew(window: window, name))
        return ControlResponse(ok: true)
    }

    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.workspaceSelect(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse {
        calls.append(.workspaceRename(target: target, window: window, name))
        return ControlResponse(ok: true)
    }

    func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.workspaceDelete(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        calls.append(.sessionMove(target: target, window: window, move))
        return ControlResponse(ok: true)
    }

    func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse {
        calls.append(.workspaceMove(target: target, window: window, direction))
        return ControlResponse(ok: true)
    }

    func focusWorkspace(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.workspaceFocus(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.sessionFlag(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func setSessionStatus(_ target: String?, window: String?,
                          update: ControlSessionStatusUpdate) -> ControlResponse {
        calls.append(.sessionStatus(target: target, window: window, update))
        return ControlResponse(ok: true)
    }

    func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.sessionSplit(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func scratchSession(_ target: String?, window: String?, mode: String?,
                        command: String?) -> ControlResponse {
        calls.append(.sessionScratch(target: target, window: window, mode, command: command))
        return ControlResponse(ok: true)
    }

    func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse {
        calls.append(.sessionFocus(target: target, window: window, pane))
        return ControlResponse(ok: true)
    }

    func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse {
        calls.append(.sessionResize(target: target, window: window, resize))
        return ControlResponse(ok: true)
    }

    func font(_ target: String?, window: String?, action: String) -> ControlResponse {
        calls.append(.font(target: target, window: window, action))
        return nextFontResponse
    }

    func reloadKeymap() -> ControlResponse {
        calls.append(.keymapReload)
        return nextKeymapResponse
    }

    func reloadGhosttyConfig() -> ControlResponse {
        calls.append(.configReload)
        return nextConfigResponse
    }

    func sendNotification(_ target: String?, window: String?,
                          title: String?, body: String) -> ControlResponse {
        calls.append(.notify(target: target, window: window, title: title, body: body))
        return nextNotifyResponse
    }

    func setTheme(name: String?) -> ControlResponse {
        calls.append(.themeSet(name))
        return nextThemeSetResponse
    }

    func listThemes() -> ControlResponse {
        calls.append(.themeList)
        return nextThemeListResponse
    }

    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse {
        calls.append(.sidebarVisibility(mode))
        return nextSidebarVisibilityResponse
    }

    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse {
        calls.append(.sidebarViewMode(mode))
        return nextSidebarViewModeResponse
    }

    func expandSidebar(window: String?) -> ControlResponse {
        calls.append(.expand(window: window))
        return nextExpandResponse
    }

    func collapseSidebar(window: String?) -> ControlResponse {
        calls.append(.collapse(window: window))
        return nextCollapseResponse
    }

    func setQuickTerminal(mode: String?) -> ControlResponse {
        calls.append(.quick(mode))
        return nextQuickResponse
    }

    func typeSession(_ target: String?, window: String?,
                     options: ControlSessionTypeOptions) async -> ControlResponse {
        calls.append(.sessionType(target: target, window: window, options))
        return nextSessionTypeResponse
    }

    func copySessionSelection(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionCopy(target: target, window: window))
        return nextSessionCopyResponse
    }

    func searchSession(_ target: String?, window: String?,
                       text: String?, to: String?) async -> ControlResponse {
        calls.append(.sessionSearch(target: target, window: window, text: text, to: to))
        return nextSessionSearchResponse
    }

    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        calls.append(.overlayOpen(target: target, window: window, options))
        return nextOverlayOpenResponse
    }

    func closeSessionOverlay(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.overlayClose(target: target, window: window))
        return nextOverlayCloseResponse
    }

    func sessionOverlayResult(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.overlayResult(target: target, window: window))
        return nextOverlayResultResponse
    }

    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse {
        calls.append(.sessionBackground(target: target, window: window, options))
        return nextSessionBackgroundResponse
    }

    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse {
        calls.append(.sessionText(target: target, window: window, options))
        return nextSessionTextResponse
    }

    func windowNew(name: String?) -> ControlResponse {
        calls.append(.windowNew(name))
        return nextWindowNewResponse
    }

    func windowList() -> ControlResponse {
        calls.append(.windowList)
        return nextWindowListResponse
    }

    func windowSelect(_ target: String?) async -> ControlResponse {
        calls.append(.windowSelect(target: target))
        return nextWindowSelectResponse
    }

    func windowClose(_ target: String?) async -> ControlResponse {
        calls.append(.windowClose(target: target))
        return nextWindowCloseResponse
    }

    func windowRename(_ target: String?, name: String) -> ControlResponse {
        calls.append(.windowRename(target: target, name))
        return nextWindowRenameResponse
    }

    func windowDelete(_ target: String?) -> ControlResponse {
        calls.append(.windowDelete(target: target))
        return nextWindowDeleteResponse
    }

    func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse {
        calls.append(.windowResize(target: target, width: width, height: height))
        return nextWindowResizeResponse
    }

    func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse {
        calls.append(.windowMove(target: target, x: x, y: y, display: display))
        return nextWindowMoveResponse
    }

    func windowZoom(_ target: String?) -> ControlResponse {
        calls.append(.windowZoom(target: target))
        return nextWindowZoomResponse
    }

    func clearRestoreCommands() -> ControlResponse {
        calls.append(.restoreClear)
        return nextRestoreClearResponse
    }
}

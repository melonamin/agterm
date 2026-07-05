import Foundation
import agtermCore

/// Linux-local synchronous control dispatcher.
///
/// Upstream `agtermCore.ControlDispatcher` is async because macOS may need to realize SwiftUI/AppKit
/// surfaces before handling some commands.
/// The GTK control server already dispatches on the GTK main thread and needs a synchronous route from
/// its C socket callback, so the Linux fork keeps this adapter inside the Linux target instead of adding
/// Linux-driven API surface to `agtermCore`.
@MainActor
struct LinuxControlDispatcher {
    private let actions: AppController

    init(actions: AppController) {
        self.actions = actions
    }

    func dispatch(_ request: ControlRequest) -> ControlResponse? {
        switch request.cmd {
        case .tree:
            return actions.controlTree(window: request.args?.window)
        case .sessionNew, .sessionSelect, .sessionGo, .sessionClose, .sessionRename,
                .sessionMove, .sessionFlag, .sessionStatus:
            return dispatchSessionCommand(request)
        case .sessionSplit, .sessionScratch, .sessionFocus, .sessionResize,
                .sessionCopy, .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResult,
                .sessionBackground, .sessionText:
            return dispatchSessionSurfaceCommand(request)
        case .sessionType:
            return nil
        case .workspaceNew, .workspaceSelect, .workspaceRename, .workspaceDelete,
                .workspaceMove, .workspaceFocus:
            return dispatchWorkspaceCommand(request)
        case .fontInc, .fontDec, .fontReset, .keymapReload, .configReload, .notify,
                .themeSet, .themeList, .sidebar, .sidebarMode, .sidebarExpand,
                .sidebarCollapse, .restoreClear:
            return dispatchAppCommand(request)
        case .windowRename, .windowResize, .windowMove, .windowZoom:
            return dispatchWindowCommand(request)
        default:
            return nil
        }
    }

    private func dispatchSessionCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionNew:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            if args?.after != nil || args?.before != nil, args?.workspace != nil || args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "session.new takes --after/--before or a workspace, not both")
            }
            if args?.workspace != nil, args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "use either --workspace or --workspace-name, not both")
            }
            if args?.createWorkspace == true, args?.workspaceName == nil {
                return ControlResponse(ok: false, error: "--create-workspace requires --workspace-name")
            }
            return actions.createSession(ControlSessionCreateOptions(
                window: args?.window,
                cwd: args?.cwd,
                workspace: args?.workspace,
                workspaceName: args?.workspaceName,
                createWorkspace: args?.createWorkspace,
                command: args?.command,
                name: args?.name,
                after: args?.after,
                before: args?.before
            ))
        case .sessionSelect:
            return actions.selectSession(request.target, window: request.args?.window)
        case .sessionGo:
            guard let dir = (request.args?.to).flatMap(SessionNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "session.go requires --to next|prev|first|last|next-attention|prev-attention")
            }
            return actions.goSession(window: request.args?.window, direction: dir)
        case .sessionClose:
            return actions.closeSession(request.target, window: request.args?.window)
        case .sessionRename:
            guard let name = request.args?.name else {
                return ControlResponse(ok: false, error: "session.rename requires a name")
            }
            return actions.renameSession(request.target, window: request.args?.window, name: name)
        case .sessionMove:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            if let anchor = args?.after ?? args?.before {
                if args?.to != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or --to, not both")
                }
                if args?.workspace != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or a workspace, not both")
                }
                return actions.moveSession(request.target, window: args?.window,
                                           move: .place(anchor: anchor, after: args?.after != nil))
            }
            if args?.to != nil && args?.workspace != nil {
                return ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both")
            }
            if let to = args?.to {
                guard let direction = ReorderDirection(rawValue: to) else {
                    return ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom")
                }
                return actions.moveSession(request.target, window: args?.window, move: .reorder(direction))
            }
            guard let workspace = args?.workspace else {
                return ControlResponse(ok: false, error: "session.move requires --to or a workspace")
            }
            return actions.moveSession(request.target, window: args?.window, move: .workspace(workspace))
        case .sessionFlag:
            return actions.setSessionFlag(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionStatus:
            guard let status = AgentStatus(rawValue: request.args?.status ?? "") else {
                return ControlResponse(ok: false, error: "invalid status")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color (expected #rrggbb)")
            }
            var pane: StatusPane?
            if let rawPane = request.args?.pane {
                guard let parsed = StatusPane(rawValue: rawPane) else {
                    return ControlResponse(ok: false, error: "--pane must be left, right, or scratch")
                }
                pane = parsed
            }
            let update = ControlSessionStatusUpdate(status: status, blink: request.args?.blink,
                                                    autoReset: request.args?.autoReset,
                                                    sound: request.args?.sound, color: request.args?.color, pane: pane)
            return actions.setSessionStatus(request.target, window: request.args?.window, update: update)
        default:
            preconditionFailure("unexpected session command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchWorkspaceCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .workspaceNew:
            return actions.createWorkspace(window: request.args?.window, name: request.args?.name)
        case .workspaceSelect:
            return actions.selectWorkspace(request.target, window: request.args?.window)
        case .workspaceRename:
            guard let name = request.args?.name?.linuxTrimmedOrNil else {
                return ControlResponse(ok: false, error: "workspace.rename requires a name")
            }
            return actions.renameWorkspace(request.target, window: request.args?.window, name: name)
        case .workspaceDelete:
            return actions.deleteWorkspace(request.target, window: request.args?.window)
        case .workspaceMove:
            guard let to = request.args?.to else {
                return ControlResponse(ok: false, error: "workspace.move requires --to")
            }
            guard let direction = ReorderDirection(rawValue: to) else {
                return ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom")
            }
            return actions.moveWorkspace(request.target, window: request.args?.window, direction: direction)
        case .workspaceFocus:
            return actions.focusWorkspace(request.target, window: request.args?.window, mode: request.args?.mode)
        default:
            preconditionFailure("unexpected workspace command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionSurfaceCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionSplit:
            return actions.splitSession(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionScratch:
            return actions.scratchSession(request.target, window: request.args?.window, mode: request.args?.mode,
                                          command: request.args?.command)
        case .sessionFocus:
            return actions.focusSessionPane(request.target, window: request.args?.window, pane: request.args?.pane)
        case .sessionResize:
            switch (request.args?.ratio, request.args?.ratioDelta) {
            case (nil, nil):
                return ControlResponse(ok: false, error: "session.resize requires --split-ratio, --grow-left, or --grow-right")
            case (.some, .some):
                return ControlResponse(ok: false, error: "session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right")
            case (.some(let ratio), nil):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .ratio(ratio))
            case (nil, .some(let delta)):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .delta(delta))
            }
        case .sessionCopy:
            return actions.copySessionSelection(request.target, window: request.args?.window)
        case .sessionOverlayOpen:
            guard let command = request.args?.command, !command.isEmpty else {
                return ControlResponse(ok: false, error: "session.overlay.open requires a command")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: request.args?.cwd,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color
                                              ))
        case .sessionOverlayClose:
            return actions.closeSessionOverlay(request.target, window: request.args?.window)
        case .sessionOverlayResult:
            return actions.sessionOverlayResult(request.target, window: request.args?.window)
        case .sessionBackground:
            return dispatchSessionBackground(request)
        case .sessionText:
            return dispatchSessionText(request)
        default:
            preconditionFailure("unexpected session surface command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchAppCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .fontInc:
            return actions.font(request.target, window: request.args?.window, action: FontBindingAction.increase)
        case .fontDec:
            return actions.font(request.target, window: request.args?.window, action: FontBindingAction.decrease)
        case .fontReset:
            return actions.font(request.target, window: request.args?.window, action: FontBindingAction.reset)
        case .keymapReload:
            return actions.reloadKeymap()
        case .configReload:
            return actions.reloadGhosttyConfig()
        case .notify:
            guard let body = request.args?.body, !body.isEmpty else {
                return ControlResponse(ok: false, error: "notify requires a body")
            }
            return actions.sendNotification(request.target, window: request.args?.window,
                                            title: request.args?.title, body: body)
        case .themeSet:
            return actions.setTheme(name: request.args?.name)
        case .themeList:
            return actions.listThemes()
        case .sidebar:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarVisibility(mode)
        case .sidebarMode:
            guard let mode = ControlSidebarViewMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarViewMode(mode)
        case .sidebarExpand:
            return actions.expandSidebar(window: request.args?.window)
        case .sidebarCollapse:
            return actions.collapseSidebar(window: request.args?.window)
        case .restoreClear:
            return actions.clearRestoreCommands()
        default:
            preconditionFailure("unexpected app command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionBackground(_ request: ControlRequest) -> ControlResponse {
        if let fit = request.args?.fit, !WatermarkConfig.isValidFit(fit) {
            return ControlResponse(ok: false, error: "invalid fit: \(fit) (contain|cover|stretch|none)")
        }
        if let position = request.args?.position, !WatermarkConfig.isValidPosition(position) {
            return ControlResponse(ok: false, error: "invalid position: \(position)")
        }
        if let opacity = request.args?.opacity, !WatermarkConfig.isValidOpacity(opacity) {
            return ControlResponse(ok: false, error: "invalid opacity: \(opacity) (0.0-1.0)")
        }
        let watermark: BackgroundWatermark?
        switch request.args?.mode {
        case "image":
            guard let path = request.args?.path, !path.isEmpty else {
                return ControlResponse(ok: false, error: "session.background image requires a path")
            }
            guard WatermarkConfig.isValidImagePath(path) else {
                return ControlResponse(ok: false, error: "image path must not contain control characters")
            }
            watermark = BackgroundWatermark(kind: .image, imagePath: path, opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)),
                                            repeats: request.args?.repeats)
        case "text":
            guard let text = request.args?.text, !text.isEmpty else {
                return ControlResponse(ok: false, error: "session.background text requires text")
            }
            guard text.count <= WatermarkConfig.maxTextLength else {
                return ControlResponse(ok: false,
                                       error: "session.background text too long (max \(WatermarkConfig.maxTextLength) characters)")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .text, text: text, colorHex: request.args?.color,
                                            opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)))
        case "color":
            guard let color = request.args?.color, !color.isEmpty else {
                return ControlResponse(ok: false, error: "session.background color requires a color")
            }
            guard WatermarkConfig.isValidColorHex(color) else {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .color, colorHex: color)
        case "clear", .none:
            watermark = nil
        default:
            return ControlResponse(ok: false,
                                   error: "invalid background mode: \(request.args?.mode ?? "") (image|text|color|clear)")
        }
        return actions.setSessionBackground(request.target, window: request.args?.window,
                                            options: ControlSessionBackgroundOptions(watermark: watermark))
    }

    private func dispatchSessionText(_ request: ControlRequest) -> ControlResponse {
        let all = request.args?.all ?? false
        let lines = request.args?.lines
        if all, lines != nil {
            return ControlResponse(ok: false, error: "use either --all or --lines, not both")
        }
        if let lines, lines <= 0 {
            return ControlResponse(ok: false, error: "--lines must be greater than 0")
        }
        return actions.readSessionText(request.target, window: request.args?.window,
                                       options: ControlSessionTextOptions(pane: request.args?.pane,
                                                                          all: all,
                                                                          lines: lines))
    }

    private func dispatchWindowCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .windowRename:
            guard let name = request.args?.name?.linuxTrimmedOrNil else {
                return ControlResponse(ok: false, error: "window.rename requires a name")
            }
            return actions.windowRename(request.target, name: name)
        case .windowResize:
            guard let width = request.args?.width, let height = request.args?.height,
                  width > 0, height > 0 else {
                return ControlResponse(ok: false, error: "window.resize requires positive width and height")
            }
            return actions.windowResize(request.target, width: width, height: height)
        case .windowMove:
            guard let x = request.args?.x, let y = request.args?.y else {
                return ControlResponse(ok: false, error: "window.move requires x and y")
            }
            return actions.windowMove(request.target, x: x, y: y, display: request.args?.display)
        case .windowZoom:
            return actions.windowZoom(request.target)
        default:
            preconditionFailure("unexpected window command: \(request.cmd.rawValue)")
        }
    }
}

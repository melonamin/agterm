import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherTests {
    @Test func treeRoutesThroughActionsWithWindowArgument() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let tree = ControlTree(workspaces: [
            ControlWorkspaceNode(id: "workspace", name: "Workspace", active: true, sessions: [])
        ])
        actions.nextTreeResponse = ControlResponse(ok: true, result: ControlResult(tree: tree))

        let response = await dispatcher.dispatch(ControlRequest(cmd: .tree, args: ControlArgs(window: "abc")))

        #expect(response == ControlResponse(ok: true, result: ControlResult(tree: tree)))
        #expect(actions.calls == [.tree(window: "abc")])
    }

    @Test func sidebarVisibilityParsesModesAndKeepsExactResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSidebarVisibilityResponse = ControlResponse(ok: true)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "hide")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.sidebarVisibility(.off)])
    }

    @Test func sidebarVisibilityDefaultsToToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sidebar))

        #expect(actions.calls == [.sidebarVisibility(.toggle)])
    }

    @Test func sidebarVisibilityRejectsInvalidModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "yes")))

        #expect(response == ControlResponse(ok: false, error: "invalid sidebar mode: yes"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sidebarViewModeParsesModesAndKeepsExactResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSidebarViewModeResponse = ControlResponse(ok: true)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "flagged")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.sidebarViewMode(.flagged)])
    }

    @Test func sidebarViewModeDefaultsToToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sidebarMode))

        #expect(actions.calls == [.sidebarViewMode(.toggle)])
    }

    @Test func sidebarViewModeRejectsInvalidModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "wide")))

        #expect(response == ControlResponse(ok: false, error: "invalid sidebar mode: wide"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sidebarExpandAndCollapseRouteWithWindowArgument() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextExpandResponse = ControlResponse(ok: true)
        actions.nextCollapseResponse = ControlResponse(ok: false, error: "window not open - window.select it first")

        let expand = await dispatcher.dispatch(ControlRequest(cmd: .sidebarExpand, args: ControlArgs(window: "win")))
        let collapse = await dispatcher.dispatch(ControlRequest(cmd: .sidebarCollapse, args: ControlArgs(window: "win")))

        #expect(expand == ControlResponse(ok: true))
        #expect(collapse == ControlResponse(ok: false, error: "window not open - window.select it first"))
        #expect(actions.calls == [.expand(window: "win"), .collapse(window: "win")])
    }

    @Test func sessionNewRoutesValidatedOptions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionNewResponse = ControlResponse(ok: true, result: ControlResult(id: "new-session"))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(name: "api", cwd: "/tmp", workspaceName: "servers", createWorkspace: true,
                              command: "top", window: "win")
        ))

        let options = ControlSessionCreateOptions(window: "win", cwd: "/tmp", workspace: nil,
                                                  workspaceName: "servers", createWorkspace: true,
                                                  command: "top", name: "api")
        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "new-session")))
        #expect(actions.calls == [.sessionNew(options)])
    }

    @Test func sessionNewRejectsAmbiguousWorkspaceArguments() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(workspace: "active", workspaceName: "servers")
        ))

        #expect(response == ControlResponse(ok: false, error: "use either --workspace or --workspace-name, not both"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionNewRejectsCreateWorkspaceWithoutName() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(createWorkspace: true)
        ))

        #expect(response == ControlResponse(ok: false, error: "--create-workspace requires --workspace-name"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionNewRoutesPlacementOptions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionNewResponse = ControlResponse(ok: true, result: ControlResult(id: "new-session"))

        let after = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(after: "active")
        ))
        let before = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(before: "anchor")
        ))

        #expect(after == ControlResponse(ok: true, result: ControlResult(id: "new-session")))
        #expect(before == ControlResponse(ok: true, result: ControlResult(id: "new-session")))
        #expect(actions.calls == [
            .sessionNew(ControlSessionCreateOptions(window: nil, cwd: nil, workspace: nil, workspaceName: nil,
                                                    createWorkspace: nil, command: nil, name: nil, after: "active")),
            .sessionNew(ControlSessionCreateOptions(window: nil, cwd: nil, workspace: nil, workspaceName: nil,
                                                    createWorkspace: nil, command: nil, name: nil, before: "anchor"))
        ])
    }

    @Test func sessionNewRejectsConflictingPlacementArguments() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let bothAnchors = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(after: "a", before: "b")
        ))
        let anchorAndWorkspace = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(workspace: "dest", after: "a")
        ))
        let anchorAndWorkspaceName = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(workspaceName: "servers", before: "a")
        ))

        #expect(bothAnchors == ControlResponse(ok: false, error: "use either --after or --before, not both"))
        #expect(anchorAndWorkspace == ControlResponse(
            ok: false, error: "session.new takes --after/--before or a workspace, not both"))
        #expect(anchorAndWorkspaceName == ControlResponse(
            ok: false, error: "session.new takes --after/--before or a workspace, not both"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionMoveRoutesPlacementForms() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let after = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "session",
            args: ControlArgs(window: "win", after: "anchor")
        ))
        let before = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "session",
            args: ControlArgs(before: "anchor")
        ))

        #expect(after == ControlResponse(ok: true))
        #expect(before == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionMove(target: "session", window: "win", .place(anchor: "anchor", after: true)),
            .sessionMove(target: "session", window: nil, .place(anchor: "anchor", after: false))
        ])
    }

    @Test func sessionMoveRejectsConflictingPlacementForms() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let bothAnchors = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(after: "a", before: "b")
        ))
        let anchorAndTo = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(to: "up", after: "a")
        ))
        let anchorAndWorkspace = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(workspace: "dest", before: "a")
        ))

        #expect(bothAnchors == ControlResponse(ok: false, error: "use either --after or --before, not both"))
        #expect(anchorAndTo == ControlResponse(
            ok: false, error: "session.move takes --after/--before or --to, not both"))
        #expect(anchorAndWorkspace == ControlResponse(
            ok: false, error: "session.move takes --after/--before or a workspace, not both"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionSelectGoCloseAndRenameRouteThroughActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let selected = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionSelect,
            target: "session",
            args: ControlArgs(window: "win")
        ))
        let navigated = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionGo,
            args: ControlArgs(window: "win", to: "next-attention")
        ))
        let closed = await dispatcher.dispatch(ControlRequest(cmd: .sessionClose, target: "session"))
        let renamed = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionRename,
            target: "session",
            args: ControlArgs(name: "api")
        ))

        #expect(selected == ControlResponse(ok: true))
        #expect(navigated == ControlResponse(ok: true))
        #expect(closed == ControlResponse(ok: true))
        #expect(renamed == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionSelect(target: "session", window: "win"),
            .sessionGo(window: "win", .nextAttention),
            .sessionClose(target: "session", window: nil),
            .sessionRename(target: "session", window: nil, "api")
        ])
    }

    @Test func sessionGoAndRenameRejectInvalidInputsWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missingDirection = await dispatcher.dispatch(ControlRequest(cmd: .sessionGo))
        let badDirection = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionGo,
            args: ControlArgs(to: "sideways")
        ))
        let missingName = await dispatcher.dispatch(ControlRequest(cmd: .sessionRename, target: "session"))

        #expect(missingDirection == ControlResponse(
            ok: false,
            error: "session.go requires --to next|prev|first|last|next-attention|prev-attention"
        ))
        #expect(badDirection == ControlResponse(
            ok: false,
            error: "session.go requires --to next|prev|first|last|next-attention|prev-attention"
        ))
        #expect(missingName == ControlResponse(ok: false, error: "session.rename requires a name"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceCommandsRouteThroughActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let created = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceNew,
            args: ControlArgs(name: "api", window: "win")
        ))
        let selected = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceSelect,
            target: "workspace",
            args: ControlArgs(window: "win")
        ))
        let renamed = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceRename,
            target: "workspace",
            args: ControlArgs(name: "  renamed  ")
        ))
        let deleted = await dispatcher.dispatch(ControlRequest(cmd: .workspaceDelete, target: "workspace"))

        #expect(created == ControlResponse(ok: true))
        #expect(selected == ControlResponse(ok: true))
        #expect(renamed == ControlResponse(ok: true))
        #expect(deleted == ControlResponse(ok: true))
        #expect(actions.calls == [
            .workspaceNew(window: "win", "api"),
            .workspaceSelect(target: "workspace", window: "win"),
            .workspaceRename(target: "workspace", window: nil, "renamed"),
            .workspaceDelete(target: "workspace", window: nil)
        ])
    }

    @Test func workspaceRenameRejectsMissingOrBlankNameWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .workspaceRename, target: "workspace"))
        let blank = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceRename,
            target: "workspace",
            args: ControlArgs(name: "   ")
        ))

        #expect(missing == ControlResponse(ok: false, error: "workspace.rename requires a name"))
        #expect(blank == ControlResponse(ok: false, error: "workspace.rename requires a name"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionMoveRoutesReorderAndWorkspaceForms() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let reorder = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "session",
            args: ControlArgs(window: "win", to: "top")
        ))
        let workspace = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "session",
            args: ControlArgs(workspace: "dest")
        ))

        #expect(reorder == ControlResponse(ok: true))
        #expect(workspace == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionMove(target: "session", window: "win", .reorder(.top)),
            .sessionMove(target: "session", window: nil, .workspace("dest"))
        ])
    }

    @Test func sessionMoveRejectsInvalidForms() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionMove, target: "active"))
        let both = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(workspace: "active", to: "up")
        ))
        let badDirection = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(to: "sideways")
        ))

        #expect(missing == ControlResponse(ok: false, error: "session.move requires --to or a workspace"))
        #expect(both == ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both"))
        #expect(badDirection == ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceMoveRoutesDirectionAndRejectsInvalidForms() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let moved = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceMove,
            target: "workspace",
            args: ControlArgs(window: "win", to: "bottom")
        ))
        let missing = await dispatcher.dispatch(ControlRequest(cmd: .workspaceMove, target: "workspace"))
        let bad = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceMove,
            target: "workspace",
            args: ControlArgs(to: "sideways")
        ))

        #expect(moved == ControlResponse(ok: true))
        #expect(missing == ControlResponse(ok: false, error: "workspace.move requires --to"))
        #expect(bad == ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom"))
        #expect(actions.calls == [.workspaceMove(target: "workspace", window: "win", .bottom)])
    }

    @Test func workspaceFocusRoutesModeForHostSideValidation() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let focused = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus,
            target: "workspace",
            args: ControlArgs(mode: "on", window: "win")
        ))

        #expect(focused == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceFocus(target: "workspace", window: "win", "on")])
    }

    @Test func sessionFlagRoutesModeForHostSideValidation() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let flagged = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionFlag,
            target: "session",
            args: ControlArgs(mode: "on", window: "win")
        ))
        let cleared = await dispatcher.dispatch(ControlRequest(cmd: .sessionFlag, args: ControlArgs(mode: "clear")))

        #expect(flagged == ControlResponse(ok: true))
        #expect(cleared == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionFlag(target: "session", window: "win", "on"),
            .sessionFlag(target: nil, window: nil, "clear")
        ])
    }

    @Test func sessionStatusRoutesParsedStatusAndRejectsInvalidStatus() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let status = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(window: "win", status: "blocked", blink: true,
                              autoReset: true, sound: "default", color: "#ff0000")
        ))
        let bad = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(status: "bogus")
        ))
        let badColor = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(status: "blocked", color: "nope")
        ))

        #expect(status == ControlResponse(ok: true))
        #expect(bad == ControlResponse(ok: false, error: "invalid status"))
        #expect(badColor == ControlResponse(ok: false, error: "invalid color (expected #rrggbb)"))
        // the bad-color request errors before reaching the actions, so only the good one is recorded.
        #expect(actions.calls == [
            .sessionStatus(target: "session", window: "win",
                           ControlSessionStatusUpdate(status: .blocked, blink: true,
                                                      autoReset: true, sound: "default", color: "#ff0000", pane: nil))
        ])
    }

    @Test func sessionStatusRevertsColorWhenOmitted() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        // set a per-call color, then set again with NO color: the second update must carry color nil,
        // proving the "next call without --color discards it" contract at the dispatch/update layer (the
        // app arm builds a fresh AgentIndicator from update.color, so a nil update.color clears the tint).
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionStatus, target: "session",
                                                     args: ControlArgs(status: "blocked", color: "#ff0000")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionStatus, target: "session",
                                                     args: ControlArgs(status: "blocked")))

        #expect(actions.calls == [
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .blocked, blink: nil, autoReset: nil,
                                                      sound: nil, color: "#ff0000")),
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .blocked, blink: nil, autoReset: nil,
                                                      sound: nil, color: nil))
        ])
    }

    @Test func sessionStatusCarriesValidPaneAndRejectsInvalidPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let tagged = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(pane: "right", status: "blocked")
        ))
        let badPane = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(pane: "middle", status: "blocked")
        ))

        #expect(tagged == ControlResponse(ok: true))
        #expect(badPane == ControlResponse(ok: false, error: "--pane must be left, right, or scratch"))
        // the invalid pane never reaches actions (status unchanged), only the valid one is recorded.
        #expect(actions.calls == [
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .blocked, blink: nil,
                                                      autoReset: nil, sound: nil, pane: .right))
        ])
    }

    @Test func sessionStatusColorErrorWinsOverInvalidPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        // both --color and --pane are invalid; color is validated first, so the color error wins.
        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(pane: "middle", status: "blocked", color: "nope")
        ))

        #expect(response == ControlResponse(ok: false, error: "invalid color (expected #rrggbb)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func splitScratchFocusAndResizeRouteParsedInputs() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let split = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionSplit,
            target: "session",
            args: ControlArgs(mode: "off", window: "win")
        ))
        let scratch = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionScratch,
            target: "session",
            args: ControlArgs(mode: "on", command: "htop")
        ))
        let focus = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionFocus,
            target: "session",
            args: ControlArgs(pane: "right")
        ))
        let resize = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionResize,
            target: "session",
            args: ControlArgs(window: "win", ratioDelta: -0.1)
        ))

        #expect(split == ControlResponse(ok: true))
        #expect(scratch == ControlResponse(ok: true))
        #expect(focus == ControlResponse(ok: true))
        #expect(resize == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionSplit(target: "session", window: "win", "off"),
            .sessionScratch(target: "session", window: nil, "on", command: "htop"),
            .sessionFocus(target: "session", window: nil, "right"),
            .sessionResize(target: "session", window: "win", .delta(-0.1))
        ])
    }

    @Test func resizeRejectsInvalidInputs() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missingResize = await dispatcher.dispatch(ControlRequest(cmd: .sessionResize, args: ControlArgs()))
        let bothResize = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionResize,
            args: ControlArgs(ratio: 0.7, ratioDelta: 0.1)
        ))

        #expect(missingResize == ControlResponse(
            ok: false,
            error: "session.resize requires --split-ratio, --grow-left, or --grow-right"
        ))
        #expect(bothResize == ControlResponse(
            ok: false,
            error: "session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right"
        ))
        #expect(actions.calls.isEmpty)
    }

    @Test func fontCommandsRouteActionsWithTargetAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextFontResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let inc = await dispatcher.dispatch(ControlRequest(
            cmd: .fontInc,
            target: "session",
            args: ControlArgs(window: "win")
        ))
        let dec = await dispatcher.dispatch(ControlRequest(cmd: .fontDec, target: "session"))
        let reset = await dispatcher.dispatch(ControlRequest(cmd: .fontReset, target: "session"))

        #expect(inc == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(dec == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(reset == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [
            .font(target: "session", window: "win", "increase_font_size:1"),
            .font(target: "session", window: nil, "decrease_font_size:1"),
            .font(target: "session", window: nil, "reset_font_size")
        ])
    }

    @Test func keymapAndConfigReloadWrapDiagnosticCounts() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextKeymapResponse = ControlResponse(ok: true, result: ControlResult(count: 2))
        actions.nextConfigResponse = ControlResponse(ok: true, result: ControlResult(count: 3))

        let keymap = await dispatcher.dispatch(ControlRequest(cmd: .keymapReload))
        let config = await dispatcher.dispatch(ControlRequest(cmd: .configReload))

        #expect(keymap == ControlResponse(ok: true, result: ControlResult(count: 2)))
        #expect(config == ControlResponse(ok: true, result: ControlResult(count: 3)))
        #expect(actions.calls == [.keymapReload, .configReload])
    }

    @Test func notifyRequiresBodyBeforeCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .notify, target: "session"))
        let empty = await dispatcher.dispatch(ControlRequest(
            cmd: .notify,
            target: "session",
            args: ControlArgs(body: "")
        ))

        #expect(missing == ControlResponse(ok: false, error: "notify requires a body"))
        #expect(empty == ControlResponse(ok: false, error: "notify requires a body"))
        #expect(actions.calls.isEmpty)
    }

    @Test func notifyRoutesBodyTitleTargetAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextNotifyResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .notify,
            target: "session",
            args: ControlArgs(window: "win", title: "Build", body: "done")
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [
            .notify(target: "session", window: "win", title: "Build", body: "done")
        ])
    }

    @Test func themeSetRoutesAndEchoesActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextThemeSetResponse = ControlResponse(ok: true, result: ControlResult(theme: "Dracula"))

        let set = await dispatcher.dispatch(ControlRequest(
            cmd: .themeSet,
            args: ControlArgs(name: "Dracula")
        ))

        #expect(set == ControlResponse(ok: true, result: ControlResult(theme: "Dracula")))
        #expect(actions.calls == [.themeSet("Dracula")])
    }

    @Test func themeSetKeepsExactActionErrorResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextThemeSetResponse = ControlResponse(ok: false, error: "unknown theme: NotARealTheme")

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .themeSet,
            args: ControlArgs(name: "NotARealTheme")
        ))

        #expect(response == ControlResponse(ok: false, error: "unknown theme: NotARealTheme"))
        #expect(actions.calls == [.themeSet("NotARealTheme")])
    }

    @Test func themeListReturnsCurrentThemeAndAvailableThemes() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextThemeListResponse = ControlResponse(
            ok: true,
            result: ControlResult(theme: "Dracula", themes: ["Dracula", "Nord"])
        )

        let response = await dispatcher.dispatch(ControlRequest(cmd: .themeList))

        #expect(response == ControlResponse(
            ok: true,
            result: ControlResult(theme: "Dracula", themes: ["Dracula", "Nord"])
        ))
        #expect(actions.calls == [.themeList])
    }

    @Test func sessionTypeRequiresTextBeforeCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionType, target: "session"))

        #expect(response == ControlResponse(ok: false, error: "session.type requires text"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionTypeRoutesParsedOptionsAndEchoesActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionTypeResponse = ControlResponse(ok: false, error: "session not realized; use select")

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionType,
            target: "session",
            args: ControlArgs(text: "ls\n", select: true, window: "win", pane: "scratch")
        ))

        #expect(response == ControlResponse(ok: false, error: "session not realized; use select"))
        #expect(actions.calls == [
            .sessionType(target: "session", window: "win",
                         ControlSessionTypeOptions(text: "ls\n", select: true, pane: "scratch"))
        ])
    }

    @Test func sessionCopyRoutesTargetAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionCopyResponse = ControlResponse(ok: true, result: ControlResult(text: "selected"))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionCopy,
            target: "session",
            args: ControlArgs(window: "win")
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(text: "selected")))
        #expect(actions.calls == [.sessionCopy(target: "session", window: "win")])
    }

    @Test func sessionCopyKeepsExactActionErrorResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionCopyResponse = ControlResponse(ok: false, error: "no selection")

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionCopy, target: "session"))

        #expect(response == ControlResponse(ok: false, error: "no selection"))
        #expect(actions.calls == [.sessionCopy(target: "session", window: nil)])
    }

    @Test func quickRoutesRawModeAndKeepsActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextQuickResponse = ControlResponse(ok: false, error: "invalid quick mode: maybe")

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .quick,
            args: ControlArgs(mode: "maybe")
        ))

        #expect(response == ControlResponse(ok: false, error: "invalid quick mode: maybe"))
        #expect(actions.calls == [.quick("maybe")])
    }

    @Test func sessionSearchRoutesRawInputsAndKeepsActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionSearchResponse = ControlResponse(
            ok: true,
            result: ControlResult(text: "2 of 5", count: 5)
        )

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionSearch,
            target: "session",
            args: ControlArgs(text: "needle", window: "win", to: "next")
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(text: "2 of 5", count: 5)))
        #expect(actions.calls == [
            .sessionSearch(target: "session", window: "win", text: "needle", to: "next")
        ])
    }

    @Test func windowLifecycleAndListCommandsRouteThroughActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let windows = [
            ControlWindowNode(id: "win-a", name: "Main", open: true, active: true),
            ControlWindowNode(id: "win-b", name: "Build", open: false, active: false)
        ]
        actions.nextWindowNewResponse = ControlResponse(ok: true, result: ControlResult(id: "win-b"))
        actions.nextWindowListResponse = ControlResponse(ok: true, result: ControlResult(windows: windows))
        actions.nextWindowSelectResponse = ControlResponse(ok: true, result: ControlResult(id: "win-b"))
        actions.nextWindowCloseResponse = ControlResponse(ok: true, result: ControlResult(id: "win-b"))
        actions.nextWindowDeleteResponse = ControlResponse(ok: false, error: "cannot delete last window")

        let created = await dispatcher.dispatch(ControlRequest(
            cmd: .windowNew,
            args: ControlArgs(name: "Build")
        ))
        let listed = await dispatcher.dispatch(ControlRequest(cmd: .windowList))
        let selected = await dispatcher.dispatch(ControlRequest(cmd: .windowSelect, target: "win-b"))
        let closed = await dispatcher.dispatch(ControlRequest(cmd: .windowClose, target: "win-b"))
        let deleted = await dispatcher.dispatch(ControlRequest(cmd: .windowDelete, target: "win-b"))

        #expect(created == ControlResponse(ok: true, result: ControlResult(id: "win-b")))
        #expect(listed == ControlResponse(ok: true, result: ControlResult(windows: windows)))
        #expect(selected == ControlResponse(ok: true, result: ControlResult(id: "win-b")))
        #expect(closed == ControlResponse(ok: true, result: ControlResult(id: "win-b")))
        #expect(deleted == ControlResponse(ok: false, error: "cannot delete last window"))
        #expect(actions.calls == [
            .windowNew("Build"),
            .windowList,
            .windowSelect(target: "win-b"),
            .windowClose(target: "win-b"),
            .windowDelete(target: "win-b")
        ])
    }

    @Test func windowCommandsRouteParsedInputsAndKeepActionResponses() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextWindowRenameResponse = ControlResponse(ok: true, result: ControlResult(id: "win"))
        actions.nextWindowResizeResponse = ControlResponse(ok: true, result: ControlResult(id: "win"))
        actions.nextWindowMoveResponse = ControlResponse(ok: true, result: ControlResult(id: "win"))
        actions.nextWindowZoomResponse = ControlResponse(ok: false, error: "window not open — window.select it first")

        let renamed = await dispatcher.dispatch(ControlRequest(
            cmd: .windowRename,
            target: "9f3c",
            args: ControlArgs(name: "  Renamed  ")
        ))
        let resized = await dispatcher.dispatch(ControlRequest(
            cmd: .windowResize,
            target: "9f3c",
            args: ControlArgs(width: 1200, height: 800)
        ))
        let moved = await dispatcher.dispatch(ControlRequest(
            cmd: .windowMove,
            target: "9f3c",
            args: ControlArgs(x: 100, y: 50, display: 1)
        ))
        let zoomed = await dispatcher.dispatch(ControlRequest(cmd: .windowZoom, target: "9f3c"))

        #expect(renamed == ControlResponse(ok: true, result: ControlResult(id: "win")))
        #expect(resized == ControlResponse(ok: true, result: ControlResult(id: "win")))
        #expect(moved == ControlResponse(ok: true, result: ControlResult(id: "win")))
        #expect(zoomed == ControlResponse(ok: false, error: "window not open — window.select it first"))
        #expect(actions.calls == [
            .windowRename(target: "9f3c", "Renamed"),
            .windowResize(target: "9f3c", width: 1200, height: 800),
            .windowMove(target: "9f3c", x: 100, y: 50, display: 1),
            .windowZoom(target: "9f3c")
        ])
    }

    @Test func windowCommandsRejectInvalidInputsBeforeCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missingName = await dispatcher.dispatch(ControlRequest(cmd: .windowRename, target: "win"))
        let blankName = await dispatcher.dispatch(ControlRequest(
            cmd: .windowRename,
            target: "win",
            args: ControlArgs(name: "   ")
        ))
        let missingResize = await dispatcher.dispatch(ControlRequest(
            cmd: .windowResize,
            target: "win",
            args: ControlArgs(width: 1200)
        ))
        let badResize = await dispatcher.dispatch(ControlRequest(
            cmd: .windowResize,
            target: "win",
            args: ControlArgs(width: 0, height: 800)
        ))
        let missingMoveY = await dispatcher.dispatch(ControlRequest(
            cmd: .windowMove,
            target: "win",
            args: ControlArgs(x: 100)
        ))

        #expect(missingName == ControlResponse(ok: false, error: "window.rename requires a name"))
        #expect(blankName == ControlResponse(ok: false, error: "window.rename requires a name"))
        #expect(missingResize == ControlResponse(ok: false, error: "window.resize requires positive width and height"))
        #expect(badResize == ControlResponse(ok: false, error: "window.resize requires positive width and height"))
        #expect(missingMoveY == ControlResponse(ok: false, error: "window.move requires x and y"))
        #expect(actions.calls.isEmpty)
    }

    @Test func windowCommandsKeepHostSideLookupAndPlatformErrors() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextWindowRenameResponse = ControlResponse(ok: false, error: "no such window: missing")
        actions.nextWindowMoveResponse = ControlResponse(ok: false, error: "display 3 out of range (have 1)")

        let missingWindow = await dispatcher.dispatch(ControlRequest(
            cmd: .windowRename,
            target: "missing",
            args: ControlArgs(name: "Renamed")
        ))
        let badDisplay = await dispatcher.dispatch(ControlRequest(
            cmd: .windowMove,
            target: "win",
            args: ControlArgs(x: 100, y: 50, display: 3)
        ))

        #expect(missingWindow == ControlResponse(ok: false, error: "no such window: missing"))
        #expect(badDisplay == ControlResponse(ok: false, error: "display 3 out of range (have 1)"))
        #expect(actions.calls == [
            .windowRename(target: "missing", "Renamed"),
            .windowMove(target: "win", x: 100, y: 50, display: 3)
        ])
    }

}

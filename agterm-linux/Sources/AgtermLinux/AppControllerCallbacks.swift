import CGtk
import Foundation

// MARK: - GTK trampolines

@MainActor
final class DirectoryChooserContext {
    let controller: AppController
    let workspaceID: UUID

    init(controller: AppController, workspaceID: UUID) {
        self.controller = controller
        self.workspaceID = workspaceID
    }
}

let onWindowActive: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { window, _, _ in
    guard let window else { return }
    MainActor.assumeIsolated {
        // GTK emits is-active while unmapping a closing window. windowWillClose removes its controller
        // from gWindows before that notification, so resolve through the live registry instead of
        // dereferencing unretained signal data that may already be deallocated.
        guard let ctl = gWindows.values.first(where: { $0.windowPointer == window }) else { return }
        if gtk_window_is_active(WIN(window)) != 0 { ctl.becameFrontmost() }
    }
}

let onWindowFullscreened: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { window, _, _ in
    guard let window else { return }
    MainActor.assumeIsolated {
        gWindows.values.first(where: { $0.windowPointer == window })?.fullscreenStateDidChange()
    }
}

let onFullscreenTransitionTimeout: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().fullscreenTransitionDidTimeout()
    }
    return 0
}

let onWindowCloseRequest: @convention(c) (OpaquePointer?, gpointer?) -> gboolean = { _, data in
    guard let data else { return 0 }
    let ctl = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
    let allow = MainActor.assumeIsolated { ctl.windowShouldClose() }
    guard allow else { return 1 }
    MainActor.assumeIsolated { ctl.windowWillClose() }
    return 0
}

let onQuitResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmQuit(id) }
}

let onCloseSessionResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmSessionClose(id) }
}

let onNewSession: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.newSession() }
}

let onNewWorkspace: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.newWorkspace() }
}

let onSidebarToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleSidebar() }
}

let onSplitToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleSplit() }
}

let onScratchToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleScratch() }
}

let onQuickToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleQuick() }
}

let onDashboardToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleDashboard() }
}

let onNewWindow: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.openNewWindow() }
}

let onFlaggedToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleFlaggedView() }
}

let onAttentionButton: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.showSessionPicker(attention: true, anchor: button) }
}

let onRecentSessionsButton: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.showSessionPicker(attention: false, anchor: button) }
}

let onRowActivated: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { list, row, _ in
    MainActor.assumeIsolated {
        guard let controller = controllerForWidget(list), let id = controller.session(forRow: row) else { return }
        controller.selectSession(id)
    }
}

let onSessionRowClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, presses, _, _, data in
    guard presses == 1, let gesture, let data else { return }
    MainActor.assumeIsolated {
        guard let controller = controllerForEventController(gesture),
              let id = controller.session(forRow: OpaquePointer(data)) else { return }
        let modifiers = gtk_event_controller_get_current_event_state(gesture).rawValue
        gtk_gesture_set_state(gesture, GTK_EVENT_SEQUENCE_CLAIMED)
        controller.handleSessionRowClick(id, modifiers: modifiers)
    }
}

let onRowRightClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, _, x, y, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        controllerForWidget(OpaquePointer(data))?.showRowContextMenu(listBox: OpaquePointer(data), x: x, y: y)
    }
}

let onWorkspaceDisclosure: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, data in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleWorkspaceCollapse(data) }
}

let onWorkspaceRowClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, nPress, x, y, data in
    MainActor.assumeIsolated {
        let controller = controllerForEventController(gesture)
        guard nPress == 1 else {
            controller?.cancelPendingWorkspaceToggle()
            return
        }
        if let gesture, let row = gtk_event_controller_get_widget(gesture),
           let picked = gtk_widget_pick(row, x, y, GTK_PICK_DEFAULT),
           gtk_widget_get_ancestor(picked, gtk_button_get_type()) != nil {
            return
        }
        controller?.scheduleWorkspaceToggle(data)
    }
}

let onWorkspaceToggleTimeout: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    return MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().firePendingWorkspaceToggle()
    }
}

let onRowDragPrepare: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer? = { source, _, _, _ in
    let uuid: String? = MainActor.assumeIsolated {
        guard let w = gtk_event_controller_get_widget(source) else { return nil }
        return controllerForEventController(source)?.session(forRow: OpaquePointer(w))?.uuidString
    }
    guard let uuid else { return nil }
    var v = GValue()
    _ = g_value_init(&v, GType(64))
    uuid.withCString { g_value_set_string(&v, $0) }
    let provider = gdk_content_provider_new_for_value(&v)
    g_value_unset(&v)
    return provider.map { OpaquePointer($0) }
}

let onRowDrop: @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { target, value, _, _, _ in
    MainActor.assumeIsolated {
        guard let value, let cstr = g_value_get_string(value),
              let w = gtk_event_controller_get_widget(target),
              let controller = controllerForEventController(target),
              let targetSid = controller.session(forRow: OpaquePointer(w)),
              let sourceSid = UUID(uuidString: String(cString: cstr)) else { return 0 }
        controller.handleSessionDrop(source: sourceSid, onto: targetSid)
        return 1
    }
}

let onHeaderDragPrepare: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer? = { source, _, _, _ in
    MainActor.assumeIsolated { controllerForEventController(source)?.cancelPendingWorkspaceToggle() }
    let payload: String? = MainActor.assumeIsolated {
        guard let w = gtk_event_controller_get_widget(source) else { return nil }
        return controllerForEventController(source)?.workspaceForHeader(OpaquePointer(w)).map { "w:\($0.uuidString)" }
    }
    guard let payload else { return nil }
    var v = GValue()
    _ = g_value_init(&v, GType(64))
    payload.withCString { g_value_set_string(&v, $0) }
    let provider = gdk_content_provider_new_for_value(&v)
    g_value_unset(&v)
    return provider.map { OpaquePointer($0) }
}

let onHeaderDrop: @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { target, value, _, _, _ in
    MainActor.assumeIsolated {
        guard let value, let cstr = g_value_get_string(value),
              let w = gtk_event_controller_get_widget(target),
              let controller = controllerForEventController(target),
              let targetWS = controller.workspaceForHeader(OpaquePointer(w)) else { return 0 }
        let s = String(cString: cstr)
        if s.hasPrefix("w:"), let src = UUID(uuidString: String(s.dropFirst(2))) {
            controller.handleWorkspaceDrop(source: src, onto: targetWS)
        } else if let src = UUID(uuidString: s) {
            controller.handleSessionToWorkspace(session: src, workspace: targetWS)
        }
        return 1
    }
}

let onSidebarDirectoryDrop: @convention(c)
    (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { target, value, _, _, _ in
    MainActor.assumeIsolated {
        guard let target, let value, let boxed = g_value_get_boxed(value),
              let widget = gtk_event_controller_get_widget(target) else { return 0 }
        let files = gdk_file_list_get_files(OpaquePointer(boxed))
        defer { if let files { g_slist_free(files) } }
        var paths: [String] = []
        var node = files
        while let current = node {
            if let data = current.pointee.data,
               let cpath = g_file_get_path(OpaquePointer(data)) {
                paths.append(String(cString: cpath))
                g_free(cpath)
            }
            node = current.pointee.next
        }
        return controllerForEventController(target)?.handleDirectoryDrop(
            paths, onto: OpaquePointer(widget)) == true ? 1 : 0
    }
}

let onDeleteWorkspaceResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmWorkspaceDelete(id) }
}

let onDeleteWindowResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmWindowDelete(id) }
}

let onRenameWindowResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmWindowRename(id) }
}

let onClearFocusPill: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.focusWorkspace(nil) }
}

let onDirectoryChosen: @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, gpointer?) -> Void = { source, result, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<DirectoryChooserContext>.fromOpaque(data).takeRetainedValue()
        defer { context.controller.resumeAutoFollow() }
        guard gWindows[context.controller.windowID] === context.controller else { return }
        guard let file = gtk_file_dialog_select_folder_finish(
            source.map { OpaquePointer($0) }, result, nil) else { return }
        defer { g_object_unref(RAW(file)) }
        guard let cpath = g_file_get_path(file) else { return }
        let path = String(cString: cpath)
        g_free(cpath)
        context.controller.createSessionInDirectory(path, workspaceID: context.workspaceID)
    }
}

let onCtxFlag: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextFlag() }
}

let onCtxFocus: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextFocusWorkspace() }
}

let onCtxMove: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, data in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextMoveToWorkspace(data) }
}

let onCtxRename: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextRename() }
}

let onCtxRevealDirectory: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextRevealDirectory() }
}

let onCtxClearStatus: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextClearStatus() }
}

let onCtxClose: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextCloseSession() }
}

let onMenuButton: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.showPalette() }
}

let onNameDoubleClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, nPress, _, _, data in
    guard nPress == 2 else { return }
    MainActor.assumeIsolated { controllerForEventController(gesture)?.beginRenameFromLabel(data) }
}

let onRenameCommit: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        controllerForWidget(data.map { OpaquePointer($0) })?.commitInlineRename(data)
    }
}

let onRenameKey: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { keys, keyval, _, _, _ in
    guard keyval == 0xFF1B else { return 0 }
    MainActor.assumeIsolated { controllerForEventController(keys)?.cancelInlineRename() }
    return 1
}

let onWorkspaceRightClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, _, x, y, data in
    MainActor.assumeIsolated {
        controllerForEventController(gesture)?.showWorkspaceContextMenu(data, x: x, y: y)
    }
}

let onCtxWorkspaceRename: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextWorkspaceRename() }
}

let onCtxWorkspaceDelete: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextWorkspaceDelete() }
}

let onPanedPosition: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { paned, _, _ in
    MainActor.assumeIsolated { controllerForWidget(paned)?.capturePanedRatio(paned) }
}

let restorePanedRatioTick: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    return MainActor.assumeIsolated {
        let context = Unmanaged<SplitRatioRestoreTickContext>.fromOpaque(data).takeUnretainedValue()
        return context.controller?.tryRestorePanedRatio(
            windowID: context.windowID, sessionID: context.sessionID,
            paned: context.paned, generation: context.generation) ?? 0
    }
}

let releaseSplitRatioRestoreTick: GDestroyNotify = { data in
    guard let data else { return }
    Unmanaged<SplitRatioRestoreTickContext>.fromOpaque(data).release()
}

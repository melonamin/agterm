import CGtk
import Foundation

// MARK: - GTK trampolines

let onWindowActive: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let ctl = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
        if gtk_window_is_active(WIN(ctl.windowPointer)) != 0 { ctl.becameFrontmost() }
    }
}

let onWindowFullscreened: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().fullscreenStateDidChange()
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

let onQuitResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { gController?.confirmQuit(id) }
}

let onCloseSessionResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, data in
    guard let data else { return }
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().confirmSessionClose(id)
    }
}

let onNewSession: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.newSession() }
}

let onNewWorkspace: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.newWorkspace() }
}

let onSidebarToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleSidebar() }
}

let onSplitToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleSplit() }
}

let onScratchToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleScratch() }
}

let onQuickToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleQuick() }
}

let onNewWindow: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.openNewWindow() }
}

let onFlaggedToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleFlaggedView() }
}

let onAttentionButton: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.showAttentionPalette() }
}

let onRowActivated: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, row, _ in
    MainActor.assumeIsolated {
        if let id = gController?.session(forRow: row) { gController?.selectSession(id) }
    }
}

let onSessionRowClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, presses, _, _, data in
    guard presses == 1, let gesture, let data else { return }
    MainActor.assumeIsolated {
        guard let id = gController?.session(forRow: OpaquePointer(data)) else { return }
        let modifiers = gtk_event_controller_get_current_event_state(gesture).rawValue
        gtk_gesture_set_state(gesture, GTK_EVENT_SEQUENCE_CLAIMED)
        gController?.handleSessionRowClick(id, modifiers: modifiers)
    }
}

let onRowRightClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, _, x, y, data in
    guard let data else { return }
    MainActor.assumeIsolated { gController?.showRowContextMenu(listBox: OpaquePointer(data), x: x, y: y) }
}

let onWorkspaceDisclosure: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { gController?.toggleWorkspaceCollapse(data) }
}

let onWorkspaceRowClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, nPress, x, y, data in
    MainActor.assumeIsolated {
        guard nPress == 1 else {
            gController?.cancelPendingWorkspaceToggle()
            return
        }
        if let gesture, let row = gtk_event_controller_get_widget(gesture),
           let picked = gtk_widget_pick(row, x, y, GTK_PICK_DEFAULT),
           gtk_widget_get_ancestor(picked, gtk_button_get_type()) != nil {
            return
        }
        gController?.scheduleWorkspaceToggle(data)
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
        return gController?.session(forRow: OpaquePointer(w))?.uuidString
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
              let targetSid = gController?.session(forRow: OpaquePointer(w)),
              let sourceSid = UUID(uuidString: String(cString: cstr)) else { return 0 }
        gController?.handleSessionDrop(source: sourceSid, onto: targetSid)
        return 1
    }
}

let onHeaderDragPrepare: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer? = { source, _, _, _ in
    MainActor.assumeIsolated { gController?.cancelPendingWorkspaceToggle() }
    let payload: String? = MainActor.assumeIsolated {
        guard let w = gtk_event_controller_get_widget(source) else { return nil }
        return gController?.workspaceForHeader(OpaquePointer(w)).map { "w:\($0.uuidString)" }
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
              let targetWS = gController?.workspaceForHeader(OpaquePointer(w)) else { return 0 }
        let s = String(cString: cstr)
        if s.hasPrefix("w:"), let src = UUID(uuidString: String(s.dropFirst(2))) {
            gController?.handleWorkspaceDrop(source: src, onto: targetWS)
        } else if let src = UUID(uuidString: s) {
            gController?.handleSessionToWorkspace(session: src, workspace: targetWS)
        }
        return 1
    }
}

let onDeleteWorkspaceResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { gController?.confirmWorkspaceDelete(id) }
}

let onDeleteWindowResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { gController?.confirmWindowDelete(id) }
}

let onRenameWindowResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { gController?.confirmWindowRename(id) }
}

let onClearFocusPill: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.focusWorkspace(nil) }
}

let onDirectoryChosen: @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, gpointer?) -> Void = { source, result, _ in
    guard let file = gtk_file_dialog_select_folder_finish(source.map { OpaquePointer($0) }, result, nil) else { return }
    guard let cpath = g_file_get_path(file) else { return }
    let path = String(cString: cpath)
    g_free(cpath)
    MainActor.assumeIsolated { gController?.createSessionInDirectory(path) }
}

let onCtxFlag: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextFlag() }
}

let onCtxFocus: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextFocusWorkspace() }
}

let onCtxMove: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { gController?.contextMoveToWorkspace(data) }
}

let onCtxRename: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextRename() }
}

let onCtxClearStatus: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextClearStatus() }
}

let onCtxClose: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextCloseSession() }
}

let onMenuButton: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.showPalette() }
}

let onNameDoubleClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, nPress, _, _, data in
    guard nPress == 2 else { return }
    MainActor.assumeIsolated { gController?.beginRenameFromLabel(data) }
}

let onRenameCommit: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { gController?.commitInlineRename(data) }
}

let onRenameKey: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { _, keyval, _, _, _ in
    guard keyval == 0xFF1B else { return 0 }
    MainActor.assumeIsolated { gController?.cancelInlineRename() }
    return 1
}

let onWorkspaceRightClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, _, x, y, data in
    MainActor.assumeIsolated { gController?.showWorkspaceContextMenu(data, x: x, y: y) }
}

let onCtxWorkspaceRename: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextWorkspaceRename() }
}

let onCtxWorkspaceDelete: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextWorkspaceDelete() }
}

let onPanedPosition: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { paned, _, _ in
    MainActor.assumeIsolated { gController?.capturePanedRatio(paned) }
}

let restorePanedRatioTick: @convention(c) (gpointer?) -> gboolean = { data in
    MainActor.assumeIsolated { gController?.tryRestorePanedRatio(data.map { OpaquePointer($0) }) ?? 0 }
}

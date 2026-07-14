import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    /// This window gained focus — make it the target for global shortcuts + control commands.
    func becameFrontmost() {
        gController = self
        library.frontmostWindowID = windowID
        library.saveIndex()
        if let id = store.selectedSessionID, let session = store.session(withID: id) {
            let hadUnseen = session.unseenCount > 0
            store.clearUnseen(id)
            if hadUnseen {
                NotificationManager.withdraw(sessionID: id)
                rebuildSidebar()
            }
            showActive()
            searchTargetSurface(for: id)?.refresh()
        }
    }

    /// Whether the window may close now, or should first confirm. Mirrors the macOS app-quit alert:
    /// closing the LAST open window quits the app + ends every running shell, so confirm that loss.
    /// A non-last window, an empty app, or an already-confirmed close proceeds immediately.
    func windowShouldClose() -> Bool {
        if confirmedClose { return true }
        let counts = library.openCounts()
        guard counts.windows <= 1, counts.sessions > 0 else { return true }
        let body = QuitPrompt.message(windows: counts.windows, sessions: counts.sessions)
        let dialog = OpaquePointer("Quit agterm?".withCString { h in body.withCString { b in adw_alert_dialog_new(h, b) } })
        "cancel".withCString { i in "Cancel".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "quit".withCString { i in "Quit".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "quit".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_DESTRUCTIVE) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onQuitResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
        return false
    }

    /// The quit-confirm responded — re-issue the close on "quit"; stay open otherwise.
    func confirmQuit(_ response: String) {
        guard response == "quit" else { return }
        confirmedClose = true
        gtk_window_close(WIN(window))
    }

    /// The window is closing: capture its size for restore-on-reopen, then tear down its surfaces and
    /// drop it from the library + registry.
    func windowWillClose() {
        commitBackgroundOpacity()
        cancelPendingWorkspaceToggle()
        cancelFullscreenTransitionTimeout()
        setTerminalZoom(.off, target: nil)
        TerminalZoomRegistry.shared.unregister(windowID)
        closeDashboard(refocus: false)
        DashboardControllerRegistry.shared.unregister(windowID)
        autoFollowCoordinator.stop()
        let w = gtk_widget_get_width(W(window)), h = gtk_widget_get_height(W(window))
        if w > 0, h > 0 { library.setGeometry(WindowGeometry.Size(width: Double(w), height: Double(h)), forWindow: windowID) }
        if linuxSettingsStore().load().restoreRunningCommand ?? false { captureForegroundCommands() }
        store.save()
        quickSurface?.teardown()
        quickSurface = nil
        quickFrame = nil
        for s in surfaces.values { s.teardown() }
        for s in splitSurfaces.values { s.teardown() }
        for s in scratchSurfaces.values { s.teardown() }
        for s in overlaySurfaces.values { s.teardown() }
        library.closeWindow(windowID)
        gWindows[windowID] = nil
        if gController === self { gController = gWindows.values.first }
    }
}

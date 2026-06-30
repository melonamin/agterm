import CGtk
import Foundation
import agtermCore

// AppController conforms to the shared `ControlActions` seam so `ControlDispatcher` (agtermCore) can drive
// the migrated control commands against it; the not-yet-migrated commands fall through to handleControl's
// inline switch. As more commands move into the dispatcher, that switch shrinks and the Linux control
// server becomes a thinner transport. All the required methods (resolveSession/Workspace, reconcile,
// rebuildSidebar, syncSidebarSelection, updateTitle, selectSession, closeSession, navigate, store) already
// exist on AppController.
extension AppController: ControlActions {
    func inject(text: String, into session: UUID, select: Bool) -> Bool {
        if let surface = focusedSurface(for: session) {
            surface.inject(text: text)
            return true
        }
        guard select else { return false }
        selectSession(session)
        reconcile()
        for _ in 0..<12 {
            while g_main_context_iteration(nil, 0) != 0 {}
            if let surface = focusedSurface(for: session) {
                surface.inject(text: text)
                return true
            }
            usleep(30_000)
        }
        return false
    }
    func readSelection(from session: UUID) -> String? {
        focusedSurface(for: session)?.readSelection()
    }
    func performFontAction(_ action: String, in session: UUID) -> Bool {
        guard let surface = store.session(withID: session)?.activeSurface as? GhosttySurface else { return false }
        surface.performBindingAction(action)
        return true
    }
    func focusPane(toSplit: Bool, in session: UUID) {
        store.setPaneFocus(toSplit, forSession: session)
        if let s = store.session(withID: session) { syncSplit(s) }
        rebuildSidebar()
        updateTitle()
        (toSplit ? splitSurfaces[session] : surfaces[session])?.grabFocus()
    }
    func foregroundCommands(for session: UUID) -> (main: [String]?, split: [String]?) {
        (surfaces[session]?.foregroundCommand(), splitSurfaces[session]?.foregroundCommand())
    }
    func postNotification(toSession session: UUID?, title: String, body: String) {
        if let session {
            _ = store.recordTerminalNotification(TerminalNotificationRecord(sessionID: session, windowID: windowID, pane: .main,
                                                                            title: title, body: body,
                                                                            firingIsFocused: false,
                                                                            appActive: false))
            rebuildSidebar()   // reflect the badge bump
        }
        let target = session.map { TerminalNotification.identity(windowID: windowID, sessionID: $0, pane: .main) }
        if NotificationManager.bannersEnabled { NotificationManager.send(title: title, body: body, sessionID: session, target: target) }
    }
    var blockedStatusSoundName: String? { SettingsStore().load().blockedStatusSoundName }
    func statusSoundError(for name: String) -> String? { StatusSoundPlayer.shared.statusSoundError(for: name) }
    func playStatusSound(_ name: String) { StatusSoundPlayer.shared.play(name) }
    func listThemes() -> [String] { Self.bundledThemes() }
    // `currentTheme` (the protocol's get) is already a property on AppController.

    // window seam: the shared WindowLibrary (the `library` stored property, set in init) is the host-free
    // state; here are the on-screen GTK ops the dispatcher needs. `presentWindow` calls the free `openWindow`
    // (WindowManager); close/resize touch the live GtkWindow and return false when it isn't open.
    func presentWindow(_ id: UUID) { openWindow(id) }
    func closeWindow(_ id: UUID) -> Bool {
        guard let ctl = gWindows[id] else { return false }
        gtk_window_close(WIN(ctl.windowPointer)); return true
    }
    func resizeWindow(_ id: UUID, width: Int, height: Int) -> Bool {
        guard let ctl = gWindows[id] else { return false }
        gtk_window_set_default_size(WIN(ctl.windowPointer), Int32(width), Int32(height)); return true
    }
}

// Top-level multi-window state: the shared WindowLibrary (one AppStore per window),
// the live windowID -> AppController registry, the AdwApplication handle (to build new
// windows), and the single control socket. AppController is per-window; `gController`
// (declared in AppController.swift) tracks the frontmost one for global/control routing.
import CGtk
import Foundation
import agtermCore

@MainActor var gLibrary: WindowLibrary!
@MainActor var gWindows: [UUID: AppController] = [:]
@MainActor var gApp: OpaquePointer?
@MainActor let gControlServer = ControlServer()

/// Route a terminal-originated desktop notification (OSC 9/777) through the shared delivery policy:
/// bump the firing session's unseen badge and post the banner UNLESS you are already looking at the
/// pane (the firing session is selected in the frontmost, GTK-active window). Falls back to a plain
/// banner when the session/window can't be resolved.
@MainActor func routeTerminalNotification(sessionID: UUID, pane: PaneRole, title: String, body: String) {
    guard let library = gLibrary,
          let store = library.store(forSession: sessionID),
          let windowID = library.windowID(forSession: sessionID) else {
        NotificationManager.send(title: title, body: body)
        return
    }
    let isFrontmostWindow = library.frontmostWindowID == windowID
    let windowActive = gWindows[windowID].map { gtk_window_is_active(WIN($0.windowPointer)) != 0 } ?? false
    let firingPaneIsFocused = store.session(withID: sessionID).map { session in
        switch pane {
        case .main: return !session.splitFocused
        case .split: return session.splitFocused
        case .overlay: return session.overlayActive
        }
    } ?? false
    let firingIsFocused = isFrontmostWindow && store.selectedSessionID == sessionID && firingPaneIsFocused
    // recordTerminalNotification bumps the unseen badge regardless of suppression; refresh the owning
    // window's sidebar so the count pill updates even when the banner is suppressed.
    let delivery = store.recordTerminalNotification(TerminalNotificationRecord(sessionID: sessionID, windowID: windowID, pane: pane,
                                                                               title: title, body: body,
                                                                               firingIsFocused: firingIsFocused,
                                                                               appActive: windowActive))
    gWindows[windowID]?.refreshSidebar()
    if let delivery, NotificationManager.bannersEnabled {
        NotificationManager.send(title: delivery.title, body: delivery.body, sessionID: sessionID, target: delivery.identity)
    }
}

/// Seed the comment-only starter config files on first launch (never overwriting an existing file), now
/// that each is wired to be effective: `ghostty.conf` (the scoped layer GhosttyApp.buildConfig loads),
/// `keymap.conf` (keymap dispatch), and `restore-denylist.conf` (tmux/screen/zellij, read by the
/// restore-running-command feature). Resolves the config directory once for all three.
@MainActor func ensureStarterFiles() {
    let env = ProcessInfo.processInfo.environment
    let dir = ConfigPaths.configDirectory(setting: linuxSettingsStore().load().configDirectory,
                                           stateDir: env["AGTERM_STATE_DIR"],
                                           home: FileManager.default.homeDirectoryForCurrentUser)
    func ensure(_ path: URL, _ content: @autoclosure () -> String) {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? content().write(to: path, atomically: true, encoding: .utf8)
    }
    ensure(ConfigPaths.ghosttyConfigPath(configDirectory: dir), ConfigPaths.starterGhosttyConfig())
    ensure(ConfigPaths.keymapPath(configDirectory: dir), ConfigPaths.starterKeymapConf())
    ensure(ConfigPaths.restoreDenylistPath(configDirectory: dir), ConfigPaths.starterRestoreDenylist())
}

/// Capture foreground commands (when restore is on), then flush every open window's snapshot + index.
@MainActor func flushOnQuit() {
    guard let library = gLibrary else { return }
    if linuxSettingsStore().load().restoreRunningCommand ?? false {
        for ctl in gWindows.values { ctl.captureForegroundCommands() }
    }
    // capture each open window's on-screen size so it restores at the same size on reopen.
    for (id, ctl) in gWindows {
        let w = gtk_widget_get_width(W(ctl.windowPointer))
        let h = gtk_widget_get_height(W(ctl.windowPointer))
        if w > 0, h > 0 { library.setGeometry(WindowGeometry.Size(width: Double(w), height: Double(h)), forWindow: id) }
    }
    library.saveAllOpen()
    library.saveIndex()
}

/// Open the window for `id` (raise it if already open).
@MainActor func openWindow(_ id: UUID) {
    if let existing = gWindows[id] {
        gtk_window_present(WIN(existing.windowPointer))
        return
    }
    _ = gLibrary.loadStore(for: id)
    gWindows[id] = AppController(app: gApp, windowID: id, library: gLibrary)
}

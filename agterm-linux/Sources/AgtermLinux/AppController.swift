// Drives the GTK UI from agtermCore's AppStore (the host-free model the macOS app
// also uses): an AdwNavigationSplitView with a workspace -> session sidebar and a
// GtkStack deck of per-session terminal surfaces. The UI is reconciled from the
// store after each mutation (GTK has no SwiftUI-style observation).
//
// GTK type note: the Swift importer maps GObject types inconsistently — some are
// typed pointers (GtkWidget/GtkWindow/GtkBox/GtkListBoxRow/AdwNavigationPage/
// AdwApplicationWindow), some opaque (GtkStack/GtkListBox/GtkLabel/GtkScrolledWindow/
// AdwHeaderBar/AdwToolbarView/AdwNavigationSplitView). Typed ones use W/WIN/GLBR/cast;
// opaque ones take the stored OpaquePointer directly.
import CGtk
import agtermCore
import Foundation

@MainActor var gController: AppController?

@MainActor
final class AppController {
    let store: AppStore             // this window's tree (owned by the shared WindowLibrary)
    let windowID: UUID
    let library: WindowLibrary

    private let window: OpaquePointer        // AdwApplicationWindow
    private let deck: OpaquePointer          // GtkStack (one page per session)
    private var contentBox: OpaquePointer?   // vertical box [search + deck-overlay]
    private var deckOverlay: OpaquePointer?  // GtkOverlay over the deck, hosts the floating quick panel
    private var switcherBox: OpaquePointer?  // the Ctrl-Tab MRU overlay (a centered overlay child while cycling)
    private var toastOverlay: OpaquePointer? // AdwToastOverlay wrapping the content, for transient banners
    private var bottomBar: OpaquePointer?    // the sidebar footer toolbar (compact/tall padding setting)
    private var glErrorLabel: OpaquePointer? // the persistent "no GL context" overlay (added once)
    private var quickSurface: GhosttySurface?  // the window-level quick terminal (floating panel)
    private var quickFrame: OpaquePointer?   // the card frame holding the quick surface
    var quickVisible = false
    private var splitToggleBtn: OpaquePointer?    // title-bar split toggle (swaps to .fill when active)
    private var scratchToggleBtn: OpaquePointer?  // title-bar scratch toggle (swaps to .fill when active)
    private var attentionButton: OpaquePointer?   // optional title-bar attention indicator button
    private let sidebarBox: OpaquePointer    // GtkBox holding per-workspace sections
    var splitView: OpaquePointer!    // AdwOverlaySplitView (collapsible sidebar)

    // Command palette (Ctrl+Shift+P)
    var paletteWindow: OpaquePointer?
    var paletteList: OpaquePointer?
    var paletteAll: [(String, () -> Void)] = []
    var paletteItems: [(String, () -> Void)] = []

    // In-terminal search bar (Ctrl+Shift+F)
    var searchBar: OpaquePointer?
    var searchEntry: OpaquePointer?
    var searchMatchLabel: OpaquePointer?
    var searchSessionID: UUID?
    var searchSurface: GhosttySurface?
    var searchTotal: Int?
    var searchSelected: Int?

    // Theme picker (live preview)
    var themeWindow: OpaquePointer?
    var themeList: OpaquePointer?
    var themeItems: [String] = []
    var themeCommitted: String?
    /// Coalesces rapid theme-picker arrow/typing previews so a burst collapses to one config rebuild
    /// (mirrors the macOS SettingsModel preview debounce). Commit/cancel/close cancel it and act now.
    let themePreviewDebouncer = Debouncer()
    static let themePreviewDebounceInterval: TimeInterval = 0.07
    /// Coalesces split-divider drag ticks into one persist of `Session.splitRatio` (~0.4 s after settle).
    let splitRatioDebouncer = Debouncer()
    /// Sessions whose split is mid-restore: the capture is suppressed for them so the initial 50/50 layout's
    /// `notify::position` can't clobber the persisted ratio before the restore applies it (cleared once set).
    var splitCaptureSuppressed: Set<UUID> = []

    var surfaces: [UUID: GhosttySurface] = [:]        // primary pane per session
    var splitSurfaces: [UUID: GhosttySurface] = [:]   // second pane (when split)
    private var scratchSurfaces: [UUID: GhosttySurface] = [:] // full-overlay scratch shell
    private var overlaySurfaces: [UUID: GhosttySurface] = [:]  // ephemeral overlay terminal (runs a command)
    private var floatingOverlayFrames: [UUID: OpaquePointer] = [:]  // overlay rendered as a floating sized panel
    var sessionPanes: [UUID: OpaquePointer] = [:]     // GtkPaned (main content) per session
    private var sessionStacks: [UUID: OpaquePointer] = [:]    // outer GtkStack (main <-> scratch), the deck page
    private var rowSession: [OpaquePointer: UUID] = [:]
    private var nameLabels: [OpaquePointer: (id: UUID, isWorkspace: Bool)] = [:]  // name label -> rename target (double-click)
    private var workspaceDiscButtons: [OpaquePointer: UUID] = [:]  // disclosure button -> workspace (collapse toggle)
    // The session/workspace currently being inline-renamed (nil = none). One value instead of an
    // id + is-workspace pair, so the "is-workspace" flag can't drift from the id.
    private enum RenameTarget {
        case session(UUID)
        case workspace(UUID)
        var id: UUID {
            switch self {
            case .session(let id), .workspace(let id): return id
            }
        }
        var isWorkspace: Bool { if case .workspace = self { return true }; return false }
    }
    private var renaming: RenameTarget?
    private var renameEntry: OpaquePointer?  // the live rename GtkEntry (focused after rebuild)
    private var workspaceListBoxes: [OpaquePointer] = []
    private var sidebarScroller: OpaquePointer?               // the sidebar's GtkScrolledWindow (scroll-to-selected)
    private var contextMenuSession: UUID?                     // the session a row context menu targets
    private var contextMoveTargets: [OpaquePointer: UUID] = [:]   // "Move to <ws>" button → target workspace
    private var contextMenuWorkspace: UUID?                   // the workspace a header context menu targets
    private var pendingDeleteWorkspace: UUID?                 // workspace awaiting the delete-confirm response
    private var pendingDeleteWindow: UUID?                    // window awaiting the delete-confirm response
    private var pendingRenameWindow: UUID?                    // window awaiting the rename-dialog response
    private var pendingRenameEntry: OpaquePointer?            // the rename dialog's GtkEntry
    private var confirmedClose = false                       // set once the quit-confirm is accepted
    var badgeEnabled = SettingsStore().load().notificationBadgeEnabled ?? true   // gates the unseen-count pill
    var sessionSwitcher = SessionSwitcherModel()                                  // Ctrl-Tab hold-to-cycle state
    private var contextMenuPopover: OpaquePointer?            // the live row context-menu popover
    private var collapsedWorkspaceIDs: Set<UUID> = []         // workspaces showing only their header (view state)

    // Keymap dispatch state (see KeymapDispatch.swift): the parsed keymap.conf, the resolved built-in
    // chord -> action map (user override else Linux default), and the custom-command leader matcher.
    // Loaded at launch + rebuilt on reload. Internal (not private) so the KeymapDispatch extension reaches them.
    var keymap = Keymap(builtinOverrides: [:], commands: [])
    var resolvedBuiltinChords: [Chord: BuiltinAction] = [:]
    var customCommandEngine = CustomCommandEngine(commands: [])   // matcher + id-lookup (shared, host-free)
    var leaderTimeout: guint = 0   // g_timeout source for the custom-command leader deadline (0 = none)

    static var homeCwd: String { ConfigPaths.defaultNewSessionCwd() }

    /// The main window, exposed to the palette extension (different file).
    var windowPointer: OpaquePointer { window }

    /// The primary surface for a session, exposed to the search extension (different file).
    func surface(for id: UUID?) -> GhosttySurface? { id.flatMap { surfaces[$0] } }

    init(app: OpaquePointer?, windowID: UUID, library: WindowLibrary) {
        // This window's tree comes from the shared WindowLibrary (which loaded/seeded/
        // migrated it from windows/<id>.json). AppStore.save() targets that per-window file.
        self.windowID = windowID
        self.library = library
        self.store = library.store(for: windowID) ?? AppStore()

        window = OpaquePointer(adw_application_window_new(APPW(app)))
        // restore the window's last on-screen size (Wayland: size only — the compositor owns position),
        // else the default. set BEFORE present so the window maps at the saved size.
        if let geo = library.geometry(forWindow: windowID), geo.width > 0, geo.height > 0 {
            gtk_window_set_default_size(WIN(window), Int32(geo.width), Int32(geo.height))
        } else {
            gtk_window_set_default_size(WIN(window), 1100, 700)
        }

        deck = OpaquePointer(gtk_stack_new())
        gtk_widget_set_hexpand(W(deck), 1)
        gtk_widget_set_vexpand(W(deck), 1)

        sidebarBox = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2))
        gtk_widget_set_vexpand(W(sidebarBox), 1)

        // Sidebar page: an EMPTY header (no top buttons, matching macOS) over a scrolled list. The
        // new-workspace / new-session / flagged actions live in the bottom bar below. The window
        // controls sit on the LEFT here (like the macOS traffic lights), not on the content header.
        let sidebarHeader = OpaquePointer(adw_header_bar_new())
        "close,minimize,maximize:".withCString { adw_header_bar_set_decoration_layout(sidebarHeader, $0) }

        let scroller = OpaquePointer(gtk_scrolled_window_new())
        sidebarScroller = scroller
        gtk_widget_add_css_class(W(scroller), "agterm-sidebar")   // theme-bg tint target
        gtk_scrolled_window_set_child(scroller, W(sidebarBox))
        gtk_widget_set_size_request(W(scroller), 240, -1)
        let sidebarToolbar = OpaquePointer(adw_toolbar_view_new())
        adw_toolbar_view_add_top_bar(sidebarToolbar, W(sidebarHeader))
        adw_toolbar_view_set_content(sidebarToolbar, W(scroller))
        // Bottom bar (mirrors the macOS sidebar footer): New Window on the left, Flagged-view toggle on
        // the right, flat buttons with a spacer between.
        let bottomBar = OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))
        self.bottomBar = bottomBar
        for m in [gtk_widget_set_margin_start, gtk_widget_set_margin_end] { m(W(bottomBar), 6) }
        applyCompactToolbar()   // top/bottom padding per the compact-toolbar setting
        func footerButton(_ icon: String, _ tip: String, _ cb: @escaping @convention(c) (OpaquePointer?, gpointer?) -> Void) -> OpaquePointer? {
            let b = OpaquePointer(gtk_button_new_from_icon_name(icon))
            gtk_widget_set_tooltip_text(W(b), tip)
            gtk_button_set_has_frame(BUTTON(b), 0)
            connect(b, "clicked", unsafeBitCast(cb, to: GCallback.self))
            return b
        }
        gtk_box_append(cast(bottomBar), W(footerButton("agterm-new-workspace-symbolic", "New Workspace", onNewWorkspace)))
        gtk_box_append(cast(bottomBar), W(footerButton("agterm-new-session-symbolic", "New Session", onNewSession)))
        let spacer = OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
        gtk_widget_set_hexpand(W(spacer), 1)
        gtk_box_append(cast(bottomBar), W(spacer))
        gtk_box_append(cast(bottomBar), W(footerButton("agterm-flag-symbolic", "Show Flagged Only", onFlaggedToggle)))
        adw_toolbar_view_add_bottom_bar(sidebarToolbar, W(bottomBar))

        // Content side: header over [search bar (hidden) + deck]. No menu button and no window controls
        // on the right (matching macOS — the window controls live on the left, on the sidebar header);
        // the right side carries only the terminal toggles. The palette is still on Ctrl+Shift+P.
        let contentHeader = OpaquePointer(adw_header_bar_new())
        adw_header_bar_set_show_end_title_buttons(contentHeader, 0)
        // Title-bar terminal toggles (mirror the macOS top-right controls). pack_end stacks leftward,
        // so the visual left-to-right order is split, scratch, quick, then the menu.
        // Sidebar toggle on the LEFT (macOS sidebar.left), always visible so a hidden sidebar can return.
        let sidebarBtn = OpaquePointer(gtk_button_new_from_icon_name("agterm-sidebar-symbolic"))
        gtk_widget_set_tooltip_text(W(sidebarBtn), "Toggle Sidebar (Ctrl+Shift+B)")
        connect(sidebarBtn, "clicked", unsafeBitCast(onSidebarToggle as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_header_bar_pack_start(contentHeader, W(sidebarBtn))
        attentionButton = OpaquePointer(gtk_button_new_from_icon_name("dialog-warning-symbolic"))
        gtk_widget_set_tooltip_text(W(attentionButton), "Show sessions that need attention (Ctrl+Shift+I)")
        gtk_button_set_has_frame(BUTTON(attentionButton), 0)
        connect(attentionButton, "clicked", unsafeBitCast(onAttentionButton as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_header_bar_pack_start(contentHeader, W(attentionButton))
        updateAttentionButton()
        @discardableResult func headerToggle(_ icon: String, _ tip: String, _ cb: @escaping @convention(c) (OpaquePointer?, gpointer?) -> Void) -> OpaquePointer? {
            let b = OpaquePointer(gtk_button_new_from_icon_name(icon))
            gtk_widget_set_tooltip_text(W(b), tip)
            connect(b, "clicked", unsafeBitCast(cb, to: GCallback.self))
            adw_header_bar_pack_end(contentHeader, W(b))
            return b
        }
        // pack_end stacks leftward, so this order yields left-to-right: Scratch, Split, Quick. Icons match
        // the macOS SF Symbols; split/scratch swap to a .fill variant when active (updateToggleIcons).
        headerToggle("agterm-quick-symbolic", "Quick Terminal (Ctrl+`)", onQuickToggle)
        splitToggleBtn = headerToggle("agterm-split-symbolic", "Toggle Split (Ctrl+Shift+D)", onSplitToggle)
        scratchToggleBtn = headerToggle("agterm-scratch-symbolic", "Scratch Terminal (Ctrl+Shift+J)", onScratchToggle)
        let contentToolbar = OpaquePointer(adw_toolbar_view_new())
        adw_toolbar_view_add_top_bar(contentToolbar, W(contentHeader))
        let contentBox = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        self.contentBox = contentBox
        buildSearchBar()
        gtk_box_append(cast(contentBox), W(searchBar))
        gtk_box_append(cast(contentBox), W(deck))
        adw_toolbar_view_set_content(contentToolbar, W(contentBox))

        // AdwOverlaySplitView gives a collapsible sidebar (toggleable, Ctrl+Shift+B).
        let split = OpaquePointer(adw_overlay_split_view_new())
        adw_overlay_split_view_set_sidebar(split, W(sidebarToolbar))
        adw_overlay_split_view_set_content(split, W(contentToolbar))
        adw_overlay_split_view_set_max_sidebar_width(split, 300)
        splitView = split
        adw_overlay_split_view_set_show_sidebar(split, store.sidebarVisible ? 1 : 0)   // honor the restored visibility at launch
        // The whole split (sidebar + deck) sits under a GtkOverlay so the quick terminal can float over
        // the FULL window content (matching macOS), not just the deck.
        let windowOverlay = OpaquePointer(gtk_overlay_new())
        self.deckOverlay = windowOverlay
        gtk_overlay_set_child(windowOverlay, W(split))
        // An AdwToastOverlay wraps the content so the app can surface transient banners (keymap/config
        // parse diagnostics, command failures) without a modal — the GTK analogue of the macOS banner.
        let toast = OpaquePointer(adw_toast_overlay_new())
        self.toastOverlay = toast
        adw_toast_overlay_set_child(toast, W(windowOverlay))
        adw_application_window_set_content(cast(window), W(toast))

        // Become frontmost on activation (routes global shortcuts + control to this window);
        // tear down + deregister when the window closes.
        let me = Unmanaged.passUnretained(self).toOpaque()
        connect(window, "notify::is-active", unsafeBitCast(onWindowActive as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        connect(window, "close-request", unsafeBitCast(onWindowCloseRequest as @convention(c) (OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), me)

        applyWindowTranslucency()
        gtk_window_present(WIN(window))
        applySidebarThemeColor()   // tint the sidebar to the terminal theme background
        reloadKeymapDiagnostics()   // load keymap.conf → built-in overrides + custom-command chords for key dispatch
        reconcile()
        becameFrontmost()
    }

    /// This window gained focus — make it the target for global shortcuts + control commands.
    func becameFrontmost() {
        gController = self
        library.frontmostWindowID = windowID
        library.saveIndex()
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
        return false   // prevent the close; the response decides
    }

    /// The quit-confirm responded — re-issue the close (now confirmed) on "quit"; stay open otherwise.
    func confirmQuit(_ response: String) {
        guard response == "quit" else { return }
        confirmedClose = true
        gtk_window_close(WIN(window))
    }

    /// The window is closing: capture its size for restore-on-reopen, then tear down its surfaces and
    /// drop it from the library + registry.
    func windowWillClose() {
        let w = gtk_widget_get_width(W(window)), h = gtk_widget_get_height(W(window))
        if w > 0, h > 0 { library.setGeometry(WindowGeometry.Size(width: Double(w), height: Double(h)), forWindow: windowID) }
        if SettingsStore().load().restoreRunningCommand ?? false { captureForegroundCommands() }
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

    // MARK: - Actions

    func newSession() {
        guard let wsID = store.currentWorkspaceID else { return }
        _ = store.addSession(toWorkspace: wsID, cwd: Self.homeCwd)
        reconcile()
    }

    func newWorkspace() {
        store.addWorkspaceSeeded(name: store.defaultWorkspaceName, cwd: Self.homeCwd)
        reconcile()
    }

    /// Open a folder picker (GtkFileDialog) and create a session rooted at the chosen directory.
    func openDirectory() {
        let dialog = gtk_file_dialog_new()
        "Open Directory".withCString { gtk_file_dialog_set_title(dialog, $0) }
        gtk_file_dialog_select_folder(dialog, WIN(window), nil, onDirectoryChosen, nil)
    }

    /// Create + select a session rooted at `cwd` (the Open Directory result).
    func createSessionInDirectory(_ cwd: String) {
        guard let wsID = store.currentWorkspaceID,
              let s = store.addSession(toWorkspace: wsID, cwd: cwd) else { return }
        reconcile()
        selectSession(s.id)
    }

    func selectSession(_ id: UUID) {
        // selectSession clears the unseen badge + an auto-reset (e.g. `completed`) glyph on BOTH the
        // visited and the previously-selected session; rebuild the sidebar when either row changes.
        let prev = store.selectedSessionID
        let focusedWorkspace = store.focusedWorkspaceID
        let needsRefresh = clearedRowChanges(id) || (prev.map(clearedRowChanges) ?? false)
        if prev != id, let owner = searchSurface {
            owner.endSearch()
            searchSessionID = nil
            searchSurface = nil
            gtk_widget_set_visible(W(searchBar), 0)
        }
        store.selectSession(id)
        let focusFilterChanged = focusedWorkspace != store.focusedWorkspaceID
        NotificationManager.withdraw(sessionID: id)   // clear any delivered banner now the session is seen
        showActive()
        syncSidebarSelection()
        updateTitle()
        if needsRefresh || focusFilterChanged { rebuildSidebar() }
    }

    /// Whether selecting `id` would change its sidebar row (an unseen badge or an auto-reset glyph clears).
    private func clearedRowChanges(_ id: UUID) -> Bool {
        guard let s = store.session(withID: id) else { return false }
        return s.unseenCount > 0 || (s.agentIndicator.autoReset && s.agentIndicator.status != .idle)
    }

    /// Re-render the sidebar (public entry so cross-window notification routing can refresh a
    /// background window's unseen badges after a bump).
    func refreshSidebar() { rebuildSidebar() }

    /// Re-push the system light/dark scheme to every live surface (on a style-manager change).
    func reapplyColorScheme() {
        for s in surfaces.values { s.applyColorScheme() }
        for s in splitSurfaces.values { s.applyColorScheme() }
        for s in scratchSurfaces.values { s.applyColorScheme() }
        for s in overlaySurfaces.values { s.applyColorScheme() }
    }

    func navigate(_ dir: SessionNavigation) {
        let attentionBefore = Set(store.attentionSessions.map(\.id))
        store.navigateSession(dir)
        let attentionChanged = attentionBefore != Set(store.attentionSessions.map(\.id))
        showActive()
        syncSidebarSelection()
        updateTitle()
        if attentionChanged {
            rebuildSidebar()
        } else {
            updateAttentionButton()
        }
    }

    /// Highlight only the active session's row across all workspace list boxes.
    func syncSidebarSelection() {
        for lb in workspaceListBoxes { gtk_list_box_unselect_all(lb) }
        guard let id = store.selectedSessionID,
              let row = rowSession.first(where: { $0.value == id })?.key,
              let parent = gtk_widget_get_parent(W(row)) else { return }
        gtk_list_box_select_row(OpaquePointer(parent), GLBR(row))
        scrollRowIntoView(row)
    }

    /// Scroll the sidebar so the selected row is visible (e.g. selecting an off-screen session via the
    /// control channel or a palette jump). Deferred so the rebuilt sidebar is allocated first.
    private func scrollRowIntoView(_ row: OpaquePointer) {
        guard let scroller = sidebarScroller else { return }
        runOnMain { MainActor.assumeIsolated {
            guard let adj = gtk_scrolled_window_get_vadjustment(scroller) else { return }
            var rx = 0.0, ry = 0.0
            guard gtk_widget_translate_coordinates(W(row), W(self.sidebarBox), 0, 0, &rx, &ry) != 0 else { return }
            let rowH = Double(gtk_widget_get_height(W(row)))
            let value = gtk_adjustment_get_value(adj), page = gtk_adjustment_get_page_size(adj)
            if ry < value {
                gtk_adjustment_set_value(adj, ry)
            } else if ry + rowH > value + page {
                gtk_adjustment_set_value(adj, ry + rowH - page)
            }
        } }
    }

    func closeSession(_ id: UUID) {
        store.closeSession(id)
        reconcile()
    }

    /// The primary pane's shell exited. Mirrors macOS: if a split pane is alive the session SURVIVES,
    /// promoted to that single pane (a primary exit must never destroy the live split shell); with no
    /// split the session closes. `AppStore.closePrimaryPane` decides promote-vs-close.
    func closePrimaryPane(_ id: UUID) {
        // Capture the survivor (the split pane) before the store clears the session's split flags.
        let survivor = splitSurfaces[id]
        store.closePrimaryPane(id)
        guard store.session(withID: id) != nil, let survivor, let paned = sessionPanes[id] else {
            reconcile()   // no split → the store closed the session; reconcile drops its widgets
            return
        }
        // Promote the survivor to the single pane: detach the dead primary (the store already freed its
        // ghostty surface; teardown never touches the glArea) and reparent the survivor from the end
        // slot to the start slot, so it fills the page and a future re-split has a free end slot.
        // Removing a child from a GtkPaned does NOT free the survivor's glArea, so its shell lives on.
        gtk_paned_set_start_child(paned, nil)
        gtk_paned_set_end_child(paned, nil)
        gtk_paned_set_start_child(paned, W(survivor.glArea))
        surfaces[id] = survivor
        splitSurfaces[id] = nil
        let sid = id
        survivor.promoteToPrimary(onExit: { [weak self] in self?.closePrimaryPane(sid) })
        survivor.queueRender()
        survivor.grabFocus()
        reconcile()
    }

    func toggleSidebar() {
        store.toggleSidebarVisible()   // saving mutator, so the visibility survives relaunch
        adw_overlay_split_view_set_show_sidebar(splitView, store.sidebarVisible ? 1 : 0)
    }

    /// Swap the split/scratch title-bar toggles to their `.fill` variant when the active session has that
    /// mode on (mirrors the macOS active-state icons). Called whenever the active session or its state
    /// changes.
    func updateToggleIcons() {
        let s = store.activeSession
        let splitOn = s?.isSplit == true
        let scratchOn = s?.scratchActive == true
        if let b = splitToggleBtn { gtk_button_set_icon_name(cast(b), splitOn ? "agterm-split-fill-symbolic" : "agterm-split-symbolic") }
        if let b = scratchToggleBtn { gtk_button_set_icon_name(cast(b), scratchOn ? "agterm-scratch-fill-symbolic" : "agterm-scratch-symbolic") }
    }

    /// Show/hide the window-level quick terminal — a fixed-height drop-down panel above the deck running
    /// a login shell, kept alive when hidden, recreated after its shell exits. The control `quick` arm
    /// and Ctrl+` both drive it.
    func setQuick(_ visible: Bool) {
        if quickFrame == nil, visible, let overlay = deckOverlay {
            let q = GhosttySurface(sessionID: UUID(), cwd: Self.homeCwd,
                                   env: SurfaceEnvironment.quickTerminal(windowID: windowID,
                                                                         socketPath: gControlServer.boundSocketPath
                                                                            ?? ControlServer.defaultSocketPath()),
                                   controller: self, reportsPaneState: false)
            q.onExit = { [weak self] in self?.closeQuick() }
            // A floating card panel over the FULL window content: rounded + shadowed (Adwaita "card"),
            // inset from the window edges (sidebar + deck visible around it), with a larger top inset to
            // clear the title-bar header.
            let frame = OpaquePointer(gtk_frame_new(nil))
            gtk_widget_add_css_class(W(frame), "card")
            gtk_widget_add_css_class(W(frame), "agterm-quick")   // opaque backing so it's not see-through
            gtk_widget_set_halign(W(frame), GTK_ALIGN_FILL)
            gtk_widget_set_valign(W(frame), GTK_ALIGN_FILL)
            gtk_widget_set_margin_top(W(frame), 56)
            for m in [gtk_widget_set_margin_start, gtk_widget_set_margin_end, gtk_widget_set_margin_bottom] {
                m(W(frame), 44)
            }
            gtk_frame_set_child(cast(frame), W(q.glArea))
            quickFrame = frame
            quickSurface = q
            gtk_overlay_add_overlay(overlay, W(frame))
        }
        guard let frame = quickFrame else { return }
        quickVisible = visible
        gtk_widget_set_visible(W(frame), visible ? 1 : 0)
        if visible { quickSurface?.grabFocus() }
    }

    func toggleQuick() { setQuick(!quickVisible) }

    /// The quick shell exited: tear it down (a fresh one spawns on next show).
    func closeQuick() {
        if let frame = quickFrame, let overlay = deckOverlay { gtk_overlay_remove_overlay(overlay, W(frame)) }
        quickSurface?.teardown()
        quickFrame = nil
        quickSurface = nil
        quickVisible = false
    }

    func toggleFlagActive() {
        guard let id = store.selectedSessionID else { return }
        store.toggleFlag(forSession: id)
        rebuildSidebar()
        syncSidebarSelection()
    }

    func toggleFlaggedView() {
        store.toggleSidebarMode()
        rebuildSidebar()
        syncSidebarSelection()
    }

    /// Unflag every session (the palette "Clear Flagged" + the `session.flag clear` control mode).
    func clearFlagged() {
        store.clearFlags()
        rebuildSidebar()
    }

    /// Expand every workspace (show all sessions) — the palette + `sidebar.expand` control arm.
    func expandWorkspaces() {
        collapsedWorkspaceIDs.removeAll()
        rebuildSidebar()
    }

    /// Toggle one workspace's collapsed state — the sidebar header disclosure triangle.
    func toggleWorkspaceCollapse(_ data: gpointer?) {
        guard let data, let wsID = workspaceDiscButtons[OpaquePointer(data)] else { return }
        if collapsedWorkspaceIDs.contains(wsID) { collapsedWorkspaceIDs.remove(wsID) } else { collapsedWorkspaceIDs.insert(wsID) }
        rebuildSidebar()
    }

    /// Collapse every workspace except the active one to a header — the palette + `sidebar.collapse` arm.
    func collapseOtherWorkspaces() {
        let active = store.currentWorkspaceID
        collapsedWorkspaceIDs = Set(store.workspaces.map(\.id).filter { $0 != active })
        rebuildSidebar()
        syncSidebarSelection()
    }

    /// Typing into a session clears a stuck blocked/completed attention glyph (the Esc-decline case).
    func clearAttentionStatus(_ id: UUID) {
        if store.clearAttentionStatusOnInput(sessionID: id) { rebuildSidebar() }
    }

    /// Reset the active session's agent status to idle (the palette "Clear Status", GUI half of
    /// `session.status idle`).
    func clearActiveStatus() {
        guard let id = store.selectedSessionID else { return }
        store.setAgentIndicator(AgentIndicator(), forSession: id)
        rebuildSidebar()
    }

    /// Move the active session to another workspace (the palette "Move Session to <ws>").
    func moveActiveSession(to workspaceID: UUID) {
        guard let id = store.selectedSessionID else { return }
        store.moveSession(id, toWorkspace: workspaceID)
        reconcile()
    }

    /// Focus the sidebar on a single workspace, or clear the focus (nil) — the GUI half of
    /// `workspace.focus`.
    func focusWorkspace(_ workspaceID: UUID?) {
        store.setFocusedWorkspace(workspaceID)
        rebuildSidebar()
    }

    /// Toggle the focus filter on the ACTIVE session's workspace (the `focus_workspace` keybind; the
    /// palette targets a specific workspace by name). Focused → unfocus; unfocused → focus it.
    func focusActiveWorkspace() {
        guard let current = store.currentWorkspaceID else { return }
        focusWorkspace(store.focusedWorkspaceID == current ? nil : current)
    }

    /// Rename the selected session (Ctrl+Shift+R / palette) — same inline path as a double-click.
    func startRenameActive() {
        if let id = store.selectedSessionID { beginRename(id: id, isWorkspace: false) }
    }

    /// Enter inline-rename for a session/workspace: render its name as a GtkEntry (rebuildSidebar swaps
    /// the label for an entry when the id matches `renaming`), then focus + select-all the entry.
    func beginRename(id: UUID, isWorkspace: Bool) {
        renaming = isWorkspace ? .workspace(id) : .session(id)
        rebuildSidebar()
        guard let e = renameEntry else { return }
        runOnMain { MainActor.assumeIsolated { _ = gtk_widget_grab_focus(W(e)); gtk_editable_select_region(e, 0, -1) } }
    }

    /// Double-click on a name label → begin its inline rename.
    func beginRenameFromLabel(_ data: gpointer?) {
        guard let data, let target = nameLabels[OpaquePointer(data)] else { return }
        beginRename(id: target.id, isWorkspace: target.isWorkspace)
    }

    /// Commit the inline rename (Enter or focus-out). `renaming` is cleared first so the focus-out that
    /// rebuildSidebar triggers can't double-commit.
    func commitInlineRename(_ entryRaw: UnsafeMutableRawPointer?) {
        guard let entryRaw, let target = renaming else { return }   // already committed → no-op
        let entry = OpaquePointer(entryRaw)
        let text = gtk_editable_get_text(entry).map { String(cString: $0) } ?? ""
        renaming = nil
        renameEntry = nil
        if !text.isEmpty {
            if target.isWorkspace { store.renameWorkspace(target.id, to: text) } else { store.renameSession(target.id, to: text) }
        }
        runOnMain { MainActor.assumeIsolated { gController?.rebuildAfterRename() } }
    }
    func rebuildAfterRename() { rebuildSidebar(); syncSidebarSelection(); updateTitle() }

    func cancelInlineRename() {
        guard renaming != nil else { return }
        renaming = nil
        renameEntry = nil
        rebuildAfterRename()
        focusedSurface()?.grabFocus()
    }

    /// A name label (session or workspace) when not renaming: a plain GtkLabel that selects on single
    /// click (the row/header handles that) and enters rename on DOUBLE click — or a focused GtkEntry when
    /// this id is being renamed.
    private func makeNameWidget(id: UUID, text: String, isWorkspace: Bool) -> OpaquePointer? {
        if renaming?.id == id {
            guard let entry = op(gtk_entry_new()) else { return nil }
            text.withCString { gtk_editable_set_text(entry, $0) }
            gtk_widget_set_hexpand(W(entry), 1)
            renameEntry = entry
            connect(entry, "activate", unsafeBitCast(onRenameCommit as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(entry))
            let kc = gtk_event_controller_key_new()
            connect(kc, "key-pressed", unsafeBitCast(onRenameKey as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self))
            gtk_widget_add_controller(W(entry), kc)
            let fc = gtk_event_controller_focus_new()
            connect(fc, "leave", unsafeBitCast(onRenameCommit as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(entry))
            gtk_widget_add_controller(W(entry), fc)
            return entry
        }
        guard let label = op(gtk_label_new(text)) else { return nil }
        gtk_label_set_xalign(label, 0)
        gtk_widget_set_hexpand(W(label), 1)
        nameLabels[label] = (id, isWorkspace)
        let dbl = gtk_gesture_click_new()
        gtk_gesture_single_set_button(dbl, 1)   // left double-click only; right-click goes to the context menu
        connect(dbl, "pressed", unsafeBitCast(onNameDoubleClick as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), RAW(label))
        gtk_widget_add_controller(W(label), dbl)
        return label
    }

    func reorderActiveSession(_ dir: ReorderDirection) {
        guard let id = store.selectedSessionID else { return }
        store.reorderSession(id, dir)
        rebuildSidebar()
        syncSidebarSelection()
    }

    /// Move the active workspace up/down in the sidebar (the GUI half of the `workspace.move` control arm).
    func reorderActiveWorkspace(_ dir: ReorderDirection) {
        guard let id = store.currentWorkspaceID else { return }
        store.reorderWorkspace(id, dir)
        rebuildSidebar()
        syncSidebarSelection()
    }

    func toggleSplit() {
        guard let id = store.selectedSessionID else { return }
        store.toggleSplit(id)
        reconcile()
        updateToggleIcons()
        focusedSurface(for: id)?.grabFocus()
    }

    func closeSplitPane(_ id: UUID) {
        store.closeSplitPane(id)
        reconcile()
        surfaces[id]?.grabFocus()
    }

    func toggleScratch() {
        guard let id = store.selectedSessionID else { return }
        store.toggleScratch(id)
        reconcile()
        updateToggleIcons()
    }

    /// Move keyboard focus between the two split panes of the active session.
    func focusPane(left: Bool) {
        guard let id = store.selectedSessionID, store.session(withID: id)?.hasSplit == true else { return }
        (left ? surfaces[id] : splitSurfaces[id])?.grabFocus()
    }

    /// Ctrl+Tab: jump to the most-recently-used OTHER session. Selecting re-pushes recency,
    /// so a second Ctrl+Tab toggles back (Alt-Tab-between-two).
    /// Ctrl-Tab: begin (or advance) the hold-to-cycle MRU switch via the shared SessionSwitcherModel. The
    /// first press lands on the most-recent OTHER session; further presses (while Ctrl is held) walk the
    /// MRU; releasing Ctrl commits (endSessionSwitch). The snapshot insulates the cycle from the recency
    /// reordering each in-cycle selection triggers.
    func quickSwitchSession() {
        if sessionSwitcher.isActive {
            if let id = sessionSwitcher.advance() { selectSession(id) }
        } else {
            let valid = Set(store.navigableSessions.map(\.id))
            let mru = store.sessionRecency.top(valid.count, in: valid)
            if let id = sessionSwitcher.begin(mru) { selectSession(id) }
        }
        if sessionSwitcher.isActive { showSwitcherOverlay() }
    }

    /// Ctrl released → commit the cycle so the next Ctrl-Tab starts fresh from the new MRU order.
    func endSessionSwitch() { sessionSwitcher.end(); hideSwitcherOverlay() }

    /// Show/refresh the MRU switch overlay: a centered card listing the cycle's sessions (most-recent
    /// first) with the current one highlighted. A GtkOverlay child over the deck, rebuilt on each advance.
    private func showSwitcherOverlay() {
        hideSwitcherOverlay()
        guard let overlay = deckOverlay, let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)) else { return }
        gtk_widget_set_halign(W(box), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(W(box), GTK_ALIGN_CENTER)
        gtk_widget_add_css_class(W(box), "agterm-switcher")
        for id in sessionSwitcher.ordered {
            guard let s = store.session(withID: id), let label = op(gtk_label_new(s.displayName)) else { continue }
            gtk_widget_set_margin_start(W(label), 18); gtk_widget_set_margin_end(W(label), 18)
            gtk_label_set_xalign(label, 0)
            if id == sessionSwitcher.current { gtk_widget_add_css_class(W(label), "agterm-switcher-current") }
            gtk_box_append(cast(box), W(label))
        }
        switcherBox = box
        gtk_overlay_add_overlay(overlay, W(box))
    }

    private func hideSwitcherOverlay() {
        if let overlay = deckOverlay, let box = switcherBox { gtk_overlay_remove_overlay(overlay, W(box)) }
        switcherBox = nil
    }

    /// Show a persistent, centered message when the GtkGLArea can't create a GL context (VM/headless/
    /// llvmpipe-less/Wayland-no-GL) — the terminal can't render, so explain it instead of a blank pane.
    /// Added once over the deck; a GL failure is display-wide so a single message suffices.
    func showGLError() {
        guard let overlay = deckOverlay, glErrorLabel == nil else { return }
        let msg = "Terminal rendering needs OpenGL.\n\nNo GL context is available — check your GPU drivers, " +
                  "or enable 3D acceleration if you're running in a VM."
        guard let label = op(gtk_label_new(msg)) else { return }
        gtk_label_set_justify(label, GTK_JUSTIFY_CENTER)
        gtk_label_set_wrap(label, 1)
        gtk_widget_set_halign(W(label), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(W(label), GTK_ALIGN_CENTER)
        gtk_widget_add_css_class(W(label), "agterm-gl-error")
        glErrorLabel = label
        gtk_overlay_add_overlay(overlay, W(label))
    }

    /// Surface a transient banner (AdwToast) over the window content — keymap/config parse diagnostics
    /// and other non-modal alerts. No-op before the content (and its toast overlay) is built.
    func showToast(_ message: String) {
        guard let overlay = toastOverlay else { return }
        message.withCString { adw_toast_overlay_add_toast(overlay, adw_toast_new($0)) }
    }

    /// Apply the compact-toolbar setting to the sidebar footer's vertical padding: compact (the default)
    /// is tight, off is a taller bar — the GTK analogue of the macOS compact vs tall window toolbar.
    func applyCompactToolbar() {
        guard let bar = bottomBar else { return }
        let pad = Int32((SettingsStore().load().compactToolbar ?? true) ? 4 : 14)
        gtk_widget_set_margin_top(W(bar), pad)
        gtk_widget_set_margin_bottom(W(bar), pad)
    }

    /// Toggle the window's transparent-background class so ghostty's `background-opacity` alpha reaches
    /// the compositor (terminal translucency). At full opacity the class is removed and the window is
    /// opaque again. Blur, if any, is the compositor's (no app-controllable Wayland blur protocol).
    func applyWindowTranslucency() {
        let translucent = (SettingsStore().load().backgroundOpacity ?? 1) < 1
        "agterm-translucent".withCString {
            if translucent {
                gtk_widget_add_css_class(W(window), $0)
            } else {
                gtk_widget_remove_css_class(W(window), $0)
            }
        }
    }

    func closeScratch(_ id: UUID) {
        store.closeScratch(id)
        reconcile()
    }

    /// Re-render every live surface with `name` (nil/empty = ghostty's built-in colors) layered over
    /// the persisted font/size/scroll settings, WITHOUT persisting — used for live theme-picker
    /// preview and as the config-reload path, so neither drops the non-theme settings.
    func previewTheme(_ name: String?) {
        var settings = SettingsStore().load()
        settings.theme = (name?.isEmpty == false) ? name : nil
        let lines = Self.ghosttyLines(for: settings)
        guard let cfg = GhosttyApp.shared.buildConfig(extraLines: lines) else { return }
        GhosttyApp.shared.updateConfig(cfg)
        for ctl in gWindows.values {
            for s in ctl.configurableSurfaces {
                s.applyConfig(cfg)
                s.reapplyWatermarkIfNeeded()
            }
        }
        ghostty_config_free(cfg)
        // The embedded GL renderer ignores the config's colors, so ALSO push them as OSC to every live
        // surface — and cache them for surfaces created later (new sessions, restored panes).
        let osc = AppSettings.themeOSC(from: lines)
        let liveOSC = osc.isEmpty && settings.theme == nil ? AppSettings.themeResetOSC : osc
        GhosttyApp.shared.currentThemeOSC = liveOSC
        for ctl in gWindows.values {
            for s in ctl.configurableSurfaces {
                s.feed(liveOSC)
                s.queueRender()
            }
            ctl.applyWindowThemeColors(for: settings.theme)   // re-theme every open window chrome
        }
    }

    /// Apply a ghostty theme to every live surface and persist it so it survives relaunch.
    func applyTheme(_ name: String?) {
        var settings = SettingsStore().load()
        settings.theme = (name?.isEmpty == false) ? name : nil
        try? SettingsStore().save(settings)
        previewTheme(settings.theme)   // re-renders surfaces + the whole-window chrome
    }

    /// The persisted theme (nil = ghostty default), so the picker can revert on cancel.
    var currentTheme: String? { SettingsStore().load().theme }

    /// Reload ghostty config (re-reads ~/.config/ghostty + the persisted theme) into every
    /// live surface — the control `config.reload`, no restart needed.
    func reloadConfig() { previewTheme(currentTheme) }

    /// Bundled ghostty theme names (the file names in the resolved themes dir).
    nonisolated static func bundledThemes() -> [String] {
        var names = themesDir().map { ThemeCatalog.names(in: $0) } ?? []
        if !names.contains(AppSettings.defaultTheme) {
            names.append(AppSettings.defaultTheme)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The ghostty config lines for `settings`, with the seeded `agterm` default theme INLINED when it
    /// isn't a findable theme file — Linux ships none of its own ghostty resources, so it falls back to
    /// the system themes dir, which doesn't carry `agterm`. Without this the default look silently
    /// degrades to ghostty's built-in default. macOS stages the theme file, so this would be a no-op there.
    nonisolated static func ghosttyLines(for settings: AppSettings) -> [String] {
        var lines = settings.ghosttyConfigLines()
        if settings.theme == AppSettings.defaultTheme, themeFileLines(for: AppSettings.defaultTheme) == nil {
            lines.removeAll { $0 == "theme = \(AppSettings.defaultTheme)" }
            lines.append(contentsOf: AppSettings.agtermThemeLines)
        } else if let theme = settings.theme, let themeLines = themeFileLines(for: theme) {
            // libghostty's `theme = <name>` resolution is a no-op in the embedded `-Dapp-runtime=none`
            // build (it doesn't search GHOSTTY_RESOURCES_DIR), so a named theme never reached the surface
            // — only the default worked, because it inlines its colors. Inline the theme FILE's own config
            // lines instead (a theme file IS a ghostty config snippet), which actually applies it.
            lines.removeAll { $0 == "theme = \(theme)" }
            lines.append(contentsOf: themeLines)
        }
        return lines
    }

    /// The raw config lines of a bundled theme file (palette/background/foreground/cursor/…), resolved
    /// through the same themes dir as the picker; nil if the theme isn't a findable file (then the
    /// `theme = <name>` line stays and ghostty's default colors remain).
    nonisolated static func themeFileLines(for theme: String) -> [String]? {
        guard let dir = themesDir() else { return nil }
        let path = (dir as NSString).appendingPathComponent(theme)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.isEmpty ? nil : lines
    }

    /// The ghostty themes dir, resolved through the SAME `GhosttyResourceResolver` + candidate list that
    /// sets `GHOSTTY_RESOURCES_DIR` (themes live under `<resources>/themes`); a system themes-only dir is
    /// the last-ditch fallback for installs that ship themes without the full resources.
    nonisolated static func themesDir() -> String? {
        let resolver = GhosttyResourceResolver(candidates: ghosttyResourceCandidates(),
                                               fileExists: { FileManager.default.fileExists(atPath: $0) })
        if let dir = resolver.resolve() {
            let themes = (dir as NSString).appendingPathComponent("themes")
            if FileManager.default.fileExists(atPath: themes) { return themes }
        }
        return ["/usr/share/ghostty/themes", "/usr/local/share/ghostty/themes"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// A given theme's chrome colors (shared resolver), with the inline `agterm` lines as the fallback
    /// for the seeded default that isn't a findable theme file.
    nonisolated static func themeColors(for theme: String?) -> ThemeColors {
        // The agterm default isn't a findable file → fall back to its inline lines; any OTHER missing
        // theme falls back to no tint (keep the Adwaita chrome) rather than borrowing agterm's colors.
        let fallback = (theme == AppSettings.defaultTheme) ? AppSettings.agtermThemeLines : []
        return ThemeColorResolver.colors(forTheme: theme, themesDir: themesDir(), fallbackLines: fallback)
    }

    static var sidebarThemeProvider: OpaquePointer?

    /// Theme the WHOLE window chrome — header bars, content area, popovers, and the sidebar — to the
    /// terminal theme, so a theme change (and the live picker preview) re-colors the entire window, not
    /// just the terminal. Overriding libadwaita's named colors (`@window_bg_color`, `@headerbar_bg_color`,
    /// `@view_bg_color`, …) re-themes the whole Adwaita stylesheet at once; the explicit `.agterm-sidebar`
    /// rules carry the shifted sidebar tint. Display-wide provider above the app CSS, re-applied on every
    /// theme/preview. A theme with no background drops the override so the Adwaita defaults return.
    func applyWindowThemeColors(for theme: String?) {
        guard let display = gdk_display_get_default() else { return }
        let colors = Self.themeColors(for: theme)
        guard let themeBg = colors.background else {
            if let p = Self.sidebarThemeProvider {   // default theme → restore Adwaita's own chrome
                gtk_style_context_remove_provider_for_display(display, p)
                Self.sidebarThemeProvider = nil
            }
            return
        }
        let fg = colors.foreground ?? "inherit"
        let sel = colors.selectionBackground ?? themeBg
        // Sidebar tint: shift the theme background darker (>5) / lighter (<5) per the Sidebar Tint setting.
        let shift = SettingsStore().load().sidebarBackgroundShift ?? AppSettings.defaultSidebarBackgroundShift
        let sidebarBg = ThemeColorResolver.shiftedHex(themeBg, amount: AppSettings.sidebarShiftAmount(strength: shift))
        let css = """
        @define-color window_bg_color \(themeBg);
        @define-color window_fg_color \(fg);
        @define-color view_bg_color \(themeBg);
        @define-color view_fg_color \(fg);
        @define-color headerbar_bg_color \(themeBg);
        @define-color headerbar_fg_color \(fg);
        @define-color popover_bg_color \(themeBg);
        @define-color popover_fg_color \(fg);
        @define-color sidebar_bg_color \(sidebarBg);
        @define-color sidebar_fg_color \(fg);
        .agterm-sidebar { background-color: \(sidebarBg); }
        .agterm-sidebar list, .agterm-sidebar row { background-color: transparent; }
        .agterm-sidebar row:selected { background-color: \(sel); }
        .agterm-sidebar label { color: \(fg); }
        """
        if Self.sidebarThemeProvider == nil {
            let provider = OpaquePointer(gtk_css_provider_new())
            Self.sidebarThemeProvider = provider
            gtk_style_context_add_provider_for_display(display, provider, 650)   // above the app CSS (600)
        }
        if let provider = Self.sidebarThemeProvider {
            css.withCString { gtk_css_provider_load_from_string(cast(provider), $0) }
        }
    }

    /// Re-theme the chrome to the PERSISTED theme (window build, settings change, config reload).
    func applySidebarThemeColor() { applyWindowThemeColors(for: currentTheme) }

    // MARK: - Control channel dispatch (a core subset of the macOS ControlServer)

    func handleControl(_ req: ControlRequest) -> ControlResponse {
        func ok(_ id: UUID? = nil) -> ControlResponse { ControlResponse(ok: true, result: ControlResult(id: id?.uuidString)) }
        func err(_ m: String) -> ControlResponse { ControlResponse(ok: false, error: m) }

        // The Linux-local dispatcher owns the migrated synchronous commands; the rest fall through to the
        // inline switch below. Keep it in the Linux target so GTK control-flow needs do not leak into
        // upstream macOS-only core code.
        if let resp = LinuxControlDispatcher(actions: self).dispatch(req) { return resp }

        switch req.cmd {
        case .sessionType:
            guard let text = req.args?.text else {
                return ControlResponse(ok: false, error: "session.type requires text")
            }
            return typeSessionSync(req.target, window: req.args?.window,
                                   options: ControlSessionTypeOptions(text: text,
                                                                      select: req.args?.select ?? false,
                                                                      pane: req.args?.pane))
        case .sessionSearch:
            guard let id = resolveSession(req.target) else { return sessionResolveError(req.target) }
            if req.args?.to == "close" {
                if searchSessionID == id { searchSurface?.endSearch() }
                return ok(id)
            }   // close needs no counter
            selectSession(id)
            guard let owner = searchTargetSurface(for: id) else { return err("session not realized") }
            searchSurface = owner
            owner.startSearch()   // action fires inline -> search bar is shown synchronously
            let hasQuery = req.args?.text.map { !$0.isEmpty } ?? false
            if let text = req.args?.text, !text.isEmpty {
                searchTotal = nil
                searchSelected = nil
                text.withCString { gtk_editable_set_text(searchEntry, $0) }
                owner.sendSearchQuery(text)
            }
            switch req.args?.to {                                  // navigate matches the next/prev half of macOS
            case "next": owner.navigateSearch(.next)
            case "prev", "previous": owner.navigateSearch(.previous)
            default: break
            }
            // SEARCH_TOTAL arrives in a LATER ghostty tick, so the count is nil if we return immediately.
            // Settle-poll: drain the main loop until the total lands (or a short timeout). Re-entering the
            // default context fires the queued tick → searchDidReportTotal. Only when a needle was set.
            if hasQuery {
                for _ in 0..<20 {
                    while g_main_context_iteration(nil, 0) != 0 {}   // drain queued events incl. the ghostty tick
                    if searchTotal != nil { break }
                    usleep(3000)   // 3 ms; ~60 ms worst case
                }
            }
            let display = searchDisplayText()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString,
                                                                   text: display.isEmpty ? nil : display,
                                                                   count: searchTotal))
        case .quick:
            guard let mode = ControlToggleMode.parse(req.args?.mode, on: "show", off: "hide") else {
                return err("invalid quick mode: \(req.args?.mode ?? "toggle")")
            }
            setQuick(mode.desiredValue(current: quickVisible))
            return ok()
        case .windowNew:
            let info = library.newWindow(name: req.args?.name?.linuxTrimmedOrNil)
            openWindow(info.id)
            return ok(info.id)
        case .windowList:
            return ControlResponse(ok: true, result: ControlResult(windows: library.controlWindowNodes()))
        case .windowSelect:
            guard case .resolved(let id) = library.resolveWindow(req.target ?? "active") else {
                return resolveError("window", target: req.target, candidates: library.windows.map(\.id))
            }
            openWindow(id)
            return ok(id)
        case .windowClose:
            guard case .resolved(let id) = library.resolveWindow(req.target ?? "active") else {
                return resolveError("window", target: req.target, candidates: library.windows.map(\.id))
            }
            guard let ctl = gWindows[id] else {
                library.closeWindow(id)
                return ok(id)
            }
            gtk_window_close(WIN(ctl.windowPointer))
            return ok(id)
        case .windowDelete:
            guard case .resolved(let id) = library.resolveWindow(req.target ?? "active") else {
                return resolveError("window", target: req.target, candidates: library.windows.map(\.id))
            }
            guard library.canRemoveWindow else { return err("cannot delete last window") }
            if let ctl = gWindows[id] {
                gtk_window_close(WIN(ctl.windowPointer))
            }
            library.removeWindow(id)
            return ok(id)
        case .windowMove:
            // GTK4/Wayland gives no programmatic window positioning — the compositor owns it.
            return err("window.move is not supported on this platform (the compositor controls window position)")
        default:
            return err("command not yet supported on Linux: \(req.cmd.rawValue)")
        }
    }

    func resolveSession(_ target: String?) -> UUID? {
        let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
        if case let .resolved(id) = ControlResolve.resolve(target ?? "active", candidates: candidates, active: store.selectedSessionID) { return id }
        return nil
    }

    /// The resolution error for a failed inline session resolve: an ambiguous prefix vs not-found,
    /// mirroring the shared dispatcher's notFound so the inline arm emits the SAME distinction (the
    /// UUID?-returning resolver can't carry it). Re-resolves only on the already-failed path.
    private func resolveError(_ noun: String, target: String?, candidates: [UUID]) -> ControlResponse {
        if let target, case let .ambiguous(hits) = ControlResolve.resolve(target, candidates: candidates, active: nil) {
            return ControlResponse(ok: false, error: ControlResolve.ambiguousMessage(noun: noun, target: target, hits: hits))
        }
        return ControlResponse(ok: false, error: ControlResolve.notFoundMessage(noun: noun, target: target ?? "active"))
    }
    private func sessionResolveError(_ target: String?) -> ControlResponse {
        resolveError("session", target: target, candidates: store.workspaces.flatMap { $0.sessions.map(\.id) })
    }

    /// Open a brand-new window (the New Window palette action).
    func openNewWindow() { openWindow(gLibrary.newWindow().id) }

    func resolveWorkspace(_ target: String?) -> UUID? {
        guard let target else { return nil }
        let candidates = store.workspaces.map(\.id)
        if case let .resolved(id) = ControlResolve.resolve(target, candidates: candidates, active: store.currentWorkspaceID) { return id }
        return nil
    }

    func activeSurface() -> GhosttySurface? {
        store.selectedSessionID.flatMap { focusedSurface(for: $0) }
    }

    /// The surface of the session's currently FOCUSED pane (the split pane when a split is shown and
    /// focused, else the primary). Font/binding keys target this so they hit the focused pane like the
    /// macOS first responder, rather than always the primary.
    func focusedSurface() -> GhosttySurface? {
        store.selectedSessionID.flatMap { focusedSurface(for: $0) }
    }

    func focusedSurface(for id: UUID) -> GhosttySurface? {
        guard let s = store.session(withID: id) else { return nil }
        return s.splitFocused ? (splitSurfaces[id] ?? surfaces[id]) : surfaces[id]
    }

    func searchTargetSurface(for id: UUID) -> GhosttySurface? {
        guard let s = store.session(withID: id) else { return nil }
        if s.overlayActive, let overlay = overlaySurfaces[id] { return overlay }
        if s.scratchActive, let scratch = scratchSurfaces[id] { return scratch }
        return focusedSurface(for: id)
    }

    private var configurableSurfaces: [GhosttySurface] {
        Array(surfaces.values) + Array(splitSurfaces.values) + Array(scratchSurfaces.values)
            + Array(overlaySurfaces.values) + (quickSurface.map { [$0] } ?? [])
    }

    // MARK: - Reconcile

    func reconcile() {
        for ws in store.workspaces {
            for s in ws.sessions {
                ensurePrimary(s)
                syncSplit(s)
                syncScratch(s)
                syncOverlay(s)   // after scratch so an open overlay wins the visible child
            }
        }
        // Drop closed sessions.
        let live = Set(store.workspaces.flatMap { $0.sessions.map(\.id) })
        for id in Array(surfaces.keys) where !live.contains(id) { removeSession(id) }
        rebuildSidebar()
        showActive()
        updateTitle()
        updateAttentionButton()
    }

    /// The `AGTERM_*` env injected into a session's spawned shells (main/split/scratch) so the
    /// agent-status hooks + `{AGT_X}` tokens can call back over the control socket. Shared variable
    /// set with macOS via `agtermCore.SurfaceEnvironment`.
    private func sessionEnv(for s: Session) -> [String: String] {
        SurfaceEnvironment.session(sessionID: s.id, windowID: windowID,
                                   workspaceID: store.workspace(forSession: s.id)?.id,
                                   socketPath: gControlServer.boundSocketPath ?? ControlServer.defaultSocketPath())
    }

    /// Each session's deck page is an outer GtkStack ("main" = a GtkPaned holding the
    /// pane(s), "scratch" = the full-overlay scratch shell). The primary pane is the
    /// paned's start child.
    private func ensurePrimary(_ s: Session) {
        guard surfaces[s.id] == nil,
              let paned = OpaquePointer(gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)),
              let stack = op(gtk_stack_new()) else { return }
        sessionPanes[s.id] = paned
        // capture the user's divider drags as a persisted 0...1 ratio so the split reopens where they left it.
        connect(paned, "notify::position", unsafeBitCast(onPanedPosition as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        sessionStacks[s.id] = stack
        let hadForeground = s.foregroundCommand != nil
        let restoreInput = consumeRestoreInput(&s.foregroundCommand)
        let plan = CommandRestore.restorePlan(wasRestored: s.wasRestored,
                                              restoreEnabled: restoreEnabled,
                                              hadForeground: hadForeground,
                                              foregroundInput: restoreInput,
                                              initialCommand: s.initialCommand)
        let surf = GhosttySurface(sessionID: s.id, cwd: s.effectiveCwd, command: plan.command,
                                  env: sessionEnv(for: s), controller: self, fontSize: s.fontSize,
                                  initialInput: plan.initialInput)
        let sid = s.id
        surf.onExit = { [weak self] in self?.closePrimaryPane(sid) }   // promotes a live split; else closes the session
        s.surface = surf
        surfaces[s.id] = surf
        gtk_paned_set_start_child(paned, W(surf.glArea))
        "main".withCString { _ = gtk_stack_add_named(stack, W(paned), $0) }
        s.id.uuidString.withCString { _ = gtk_stack_add_named(deck, W(stack), $0) }
    }

    /// Create/show/hide the scratch shell to match the session's scratch state. Kept
    /// alive (hidden) when toggled off; removed only when its shell exits (closeScratch).
    private func syncScratch(_ s: Session) {
        guard let stack = sessionStacks[s.id] else { return }
        if s.scratchActive {
            if scratchSurfaces[s.id] == nil {
                let command = s.scratchCommand
                s.scratchCommand = nil
                let sc = GhosttySurface(sessionID: s.id, cwd: s.effectiveCwd, command: command,
                                        env: sessionEnv(for: s), controller: self,
                                        reportsPaneState: false)
                let sid = s.id
                sc.onExit = { [weak self] in self?.closeScratch(sid) }
                s.scratchSurface = sc
                scratchSurfaces[s.id] = sc
                "scratch".withCString { _ = gtk_stack_add_named(stack, W(sc.glArea), $0) }
            }
            "scratch".withCString { gtk_stack_set_visible_child_name(stack, $0) }
        } else {
            "main".withCString { gtk_stack_set_visible_child_name(stack, $0) }
            if let sc = scratchSurfaces[s.id], s.scratchSurface == nil {   // closeScratch tore it down
                gtk_stack_remove(stack, W(sc.glArea))
                scratchSurfaces[s.id] = nil
            }
        }
    }

    /// Create/show/hide the ephemeral overlay terminal (runs `overlayCommand` over the session). Full
    /// overlay only (hides the session); the floating sized panel + exit-status capture are deferred.
    private func syncOverlay(_ s: Session) {
        guard let stack = sessionStacks[s.id] else { return }
        if s.overlayActive {
            if overlaySurfaces[s.id] == nil, let cmd = s.overlayCommand {
                // Run via the FIXED `sh -c` capture wrapper (shared OverlayCapture): the real command +
                // a temp path ride in env, the wrapper writes the exit status so session.overlay.result /
                // --block work. No stdout redirect, so a TUI renders normally.
                let codePath = NSTemporaryDirectory() + "agterm-ovl-\(UUID().uuidString).code"
                var ovlEnv = sessionEnv(for: s)
                ovlEnv[OverlayCapture.cmdEnvKey] = cmd
                ovlEnv[OverlayCapture.codeEnvKey] = codePath
                let ov = GhosttySurface(sessionID: s.id, cwd: s.overlayCwd ?? s.effectiveCwd,
                                        command: "sh -c " + Self.singleQuoted(OverlayCapture.shellLine),
                                        env: ovlEnv, controller: self, waitAfterCommand: s.overlayWait,
                                        reportsPaneState: false)
                let sid = s.id
                let owner = windowID
                ov.onExit = {
                    // Defer past ghostty's SHOW_CHILD_EXITED callback: tearing the surface down inside it
                    // (closeOverlay → gtk_stack_remove → destroy → ghostty_surface_free) is a use-after-free.
                    runOnMain { MainActor.assumeIsolated {
                        if let txt = try? String(contentsOfFile: codePath, encoding: .utf8),
                           let code = OverlayCapture.parseExitCode(txt) {
                            gWindows[owner]?.store.recordOverlayExit(sid, code: code)
                        }
                        try? FileManager.default.removeItem(atPath: codePath)
                        gWindows[owner]?.closeOverlay(sid)
                    } }
                }
                s.overlaySurface = ov
                overlaySurfaces[s.id] = ov
                if let pct = s.overlaySizePercent, let overlay = deckOverlay {
                    // FLOATING sized panel (additive — the full-overlay deck path below is untouched): a
                    // framed card over the deck at pct% centered, mirroring the quick panel. The session
                    // stays visible behind it (the deck is NOT switched to the overlay child).
                    let frame = OpaquePointer(gtk_frame_new(nil))
                    gtk_widget_add_css_class(W(frame), "card")
                    gtk_widget_add_css_class(W(frame), "agterm-quick")   // opaque backing so it's not see-through
                    gtk_widget_set_halign(W(frame), GTK_ALIGN_CENTER)
                    gtk_widget_set_valign(W(frame), GTK_ALIGN_CENTER)
                    let dw = gtk_widget_get_width(W(overlay)), dh = gtk_widget_get_height(W(overlay))
                    gtk_widget_set_size_request(W(frame), max(Int32(240), dw * Int32(pct) / 100),
                                                max(Int32(160), dh * Int32(pct) / 100))
                    gtk_frame_set_child(cast(frame), W(ov.glArea))
                    gtk_overlay_add_overlay(overlay, W(frame))
                    gtk_widget_set_visible(W(frame), s.id == store.selectedSessionID ? 1 : 0)
                    floatingOverlayFrames[s.id] = frame
                } else {
                    "overlay".withCString { _ = gtk_stack_add_named(stack, W(ov.glArea), $0) }
                }
            }
            if floatingOverlayFrames[s.id] != nil {
                overlaySurfaces[s.id]?.grabFocus()   // floating: keep the deck on the session behind the panel
            } else {
                "overlay".withCString { gtk_stack_set_visible_child_name(stack, $0) }
                overlaySurfaces[s.id]?.grabFocus()
            }
        } else if let ov = overlaySurfaces[s.id], s.overlaySurface == nil {   // closeOverlay tore it down
            if let frame = floatingOverlayFrames[s.id], let overlay = deckOverlay {
                gtk_overlay_remove_overlay(overlay, W(frame))
                floatingOverlayFrames[s.id] = nil
            } else {
                (s.scratchActive ? "scratch" : "main").withCString { gtk_stack_set_visible_child_name(stack, $0) }
                gtk_stack_remove(stack, W(ov.glArea))
            }
            overlaySurfaces[s.id] = nil
        }
    }

    /// POSIX single-quote a string (wrap in '…', escaping embedded ' as '\''), so it survives as one
    /// argument to the overlay's `sh -c`.
    private static func singleQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The overlay's command exited (or a control close): tear it down + reconcile.
    func closeOverlay(_ id: UUID) {
        store.closeOverlay(id)
        reconcile()
    }

    /// Capture each pane's live foreground command into the session model so a restart can re-run it
    /// (restore-running-command). Filtered against the user-editable restore denylist (seeded with the
    /// terminal multiplexers). Called at quit when the setting is on; the captured argv persists via
    /// `SessionSnapshot.foregroundCommand`.
    func captureForegroundCommands() {
        let denylistPath = ConfigPaths.restoreDenylistPath(configDirectory: configDirectory())
        let denylist = (try? String(contentsOf: denylistPath, encoding: .utf8)).map(CommandRestore.parseDenylist)
            ?? ["tmux", "screen", "zellij"]
        for ws in store.workspaces {
            for s in ws.sessions {
                if let argv = surfaces[s.id]?.foregroundCommand(), CommandRestore.shouldRestore(argv: argv, denylist: denylist) {
                    s.foregroundCommand = argv
                } else {
                    s.foregroundCommand = nil
                }
                let splitArgv = s.isSplit ? splitSurfaces[s.id]?.foregroundCommand() : nil
                s.splitForegroundCommand = splitArgv.flatMap {
                    CommandRestore.shouldRestore(argv: $0, denylist: denylist) ? $0 : nil
                }
            }
        }
    }

    /// Whether the restore-running-command setting is on (default off).
    private var restoreEnabled: Bool { SettingsStore().load().restoreRunningCommand ?? false }

    /// The `initial_input` that re-runs a pane's persisted foreground command (run inside the shell so
    /// its exit returns to a prompt), consuming it run-once; nil when restore is off or none was saved.
    private func consumeRestoreInput(_ argv: inout [String]?) -> String? {
        // Nil-check first so a fresh session (nothing captured) skips the restoreEnabled settings read.
        guard let captured = argv else { return nil }
        argv = nil   // run-once: a later structural save can't re-fire it
        guard restoreEnabled else { return nil }
        return CommandRestore.shellQuotedLine(captured) + "\n"
    }

    /// Parse the user's keymap.conf for custom shell commands + the parse-diagnostic count. (Built-in
    /// rebinds are not applied yet — see the keymap chord-convention note; custom commands have no such
    /// issue since the user picks the chord/runs them from the palette.)
    func loadKeymapCommands() -> (commands: [CustomCommand], diagnostics: Int) {
        let (keymap, diags) = KeymapStore(configDirectory: configDirectory()).load()
        return (keymap.commands, diags.count)
    }

    /// Run a custom shell command via `/bin/sh -c`, with the `{AGT_X}` tokens expanded and the `$AGT_*`
    /// context env set, rooted at the active session (cwd + selection).
    func runCustomCommand(_ cmd: CustomCommand) {
        let s = store.activeSession
        let workspace = s.flatMap { store.workspace(forSession: $0.id) }
        let context = CommandContext(sessionID: s?.id.uuidString ?? "", sessionName: s?.displayName ?? "",
                                     sessionPWD: s?.effectiveCwd ?? "",
                                     workspaceID: workspace?.id.uuidString ?? "",
                                     workspaceName: workspace?.name ?? "",
                                     windowID: windowID.uuidString,
                                     windowName: gLibrary.windows.first(where: { $0.id == windowID })?.name ?? "",
                                     selection: activeSurface()?.readSelection() ?? "",
                                     socket: gControlServer.boundSocketPath ?? "")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", context.expand(cmd.command)]
        var env = ProcessInfo.processInfo.environment
        for (key, value) in context.environment() { env[key] = value }
        proc.environment = env
        if !context.sessionPWD.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: context.sessionPWD, isDirectory: true)
        }
        // Surface a non-zero exit as a banner (the macOS posts a "Command failed" notification; here the
        // in-window toast is the better fit — the user just triggered it by keybind and is looking here).
        let name = cmd.name
        proc.terminationHandler = { p in
            let code = p.terminationStatus
            guard code != 0 else { return }
            runOnMain { MainActor.assumeIsolated { gController?.showToast("command failed (exit \(code)): \(name)") } }
        }
        try? proc.run()
    }

    /// The config directory holding keymap.conf / ghostty.conf (shared resolver).
    func configDirectory() -> URL {
        ConfigPaths.configDirectory(setting: SettingsStore().load().configDirectory,
                                    stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
                                    home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Open keymap.conf in the user's editor inside an overlay (composes session.overlay.open with the
    /// shared host-free editor command). GUI-only, keep-in-sync exempt.
    func editKeymap() {
        guard let id = store.selectedSessionID else { return }
        let path = ConfigPaths.keymapPath(configDirectory: configDirectory()).path
        store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95)
        reconcile()
    }

    /// Open the agterm-scoped ghostty.conf in the user's editor inside an overlay.
    func editGhosttyConfig() {
        guard let id = store.selectedSessionID else { return }
        let path = ConfigPaths.ghosttyConfigPath(configDirectory: configDirectory()).path
        store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95)
        reconcile()
    }

    /// Create/show/hide the split (second) pane to match the session's split state.
    /// The split surface is kept alive (just hidden) when collapsed, matching macOS.
    func syncSplit(_ s: Session) {
        guard let paned = sessionPanes[s.id] else { return }
        if s.isSplit, splitSurfaces[s.id] == nil {
            let split = GhosttySurface(sessionID: s.id, cwd: s.initialSplitCwd ?? s.effectiveCwd,
                                       env: sessionEnv(for: s), controller: self,
                                       isSplitPane: true, fontSize: s.fontSize, initialInput: consumeRestoreInput(&s.splitForegroundCommand))
            let sid = s.id
            split.onExit = { [weak self] in self?.closeSplitPane(sid) }
            s.splitSurface = split
            splitSurfaces[s.id] = split
            gtk_paned_set_end_child(paned, W(split.glArea))
        }
        if let split = splitSurfaces[s.id] {
            if s.splitSurface == nil {                 // closeSplit tore it down
                if let primary = surfaces[s.id]?.glArea, gtk_paned_get_start_child(paned) != W(primary) {
                    gtk_paned_set_start_child(paned, nil)
                    gtk_paned_set_start_child(paned, W(primary))
                }
                gtk_paned_set_end_child(paned, nil)
                splitSurfaces[s.id] = nil
            } else {
                layoutSplit(s, paned: paned, split: split)
                if s.isSplit {
                    // the paned just re-laid-out both panes; force a redraw so neither shows a stale frame
                    // at the old size (mirrors the macOS surface_refresh after a split change).
                    split.refresh()
                    surfaces[s.id]?.refresh()
                    restoreSplitRatio(s)   // reopen at the persisted divider ratio
                }
            }
        }
        updatePaneDim(s)   // apply/clear the inactive-pane dim when the split shows/hides
    }

    private func layoutSplit(_ s: Session, paned: OpaquePointer, split: GhosttySurface) {
        guard let primary = surfaces[s.id]?.glArea else { return }
        let primaryWidget = W(primary)
        let splitWidget = W(split.glArea)
        let showingBoth = s.isSplit
        let showingSplitMaximized = !s.isSplit && s.splitFocused
        if showingBoth {
            if gtk_paned_get_start_child(paned) != primaryWidget {
                gtk_paned_set_start_child(paned, nil)
                gtk_paned_set_start_child(paned, primaryWidget)
            }
            if gtk_paned_get_end_child(paned) != splitWidget {
                gtk_paned_set_end_child(paned, nil)
                gtk_paned_set_end_child(paned, splitWidget)
            }
            gtk_widget_set_visible(primaryWidget, 1)
            gtk_widget_set_visible(splitWidget, 1)
        } else if showingSplitMaximized {
            if gtk_paned_get_end_child(paned) == splitWidget { gtk_paned_set_end_child(paned, nil) }
            if gtk_paned_get_start_child(paned) != splitWidget {
                gtk_paned_set_start_child(paned, nil)
                gtk_paned_set_start_child(paned, splitWidget)
            }
            gtk_widget_set_visible(splitWidget, 1)
        } else {
            if gtk_paned_get_end_child(paned) == splitWidget { gtk_paned_set_end_child(paned, nil) }
            if gtk_paned_get_start_child(paned) != primaryWidget {
                gtk_paned_set_start_child(paned, nil)
                gtk_paned_set_start_child(paned, primaryWidget)
            }
            gtk_widget_set_visible(primaryWidget, 1)
        }
    }

    /// Capture the divider position as a 0...1 ratio when the user drags the split, persisting it
    /// (debounced) so the split reopens at the same ratio. The epsilon guard skips no-op notifies —
    /// including the programmatic restore set below — so there's no capture/restore feedback loop.
    func capturePanedRatio(_ paned: OpaquePointer?) {
        guard let paned, let (sid, _) = sessionPanes.first(where: { $0.value == paned }),
              !splitCaptureSuppressed.contains(sid) else { return }   // don't clobber a pending restore
        let width = gtk_widget_get_width(W(paned))
        guard width > 0 else { return }
        let ratio = Double(gtk_paned_get_position(paned)) / Double(width)
        guard ratio > AppStore.splitRatioMin, ratio < AppStore.splitRatioMax,
              let s = store.session(withID: sid) else { return }
        if let cur = s.splitRatio, abs(cur - ratio) < 0.004 { return }
        s.splitRatio = ratio
        splitRatioDebouncer.schedule(after: 0.4) { [weak self] in self?.store.save() }
    }

    /// Restore the persisted divider ratio when the split shows: set it now if the paned is laid out, else
    /// retry on a 50 ms timer until it gets a width (a split restored at launch has none until the window maps).
    private func restoreSplitRatio(_ s: Session) {
        guard let paned = sessionPanes[s.id], s.splitRatio != nil else { return }
        splitCaptureSuppressed.insert(s.id)   // hold off the capture until the restore below lands
        if tryRestorePanedRatio(paned) != 0 {
            _ = g_timeout_add(50, restorePanedRatioTick, UnsafeMutableRawPointer(paned))
        }
    }

    /// Set the divider to the persisted ratio; returns the GSource verdict so the retry timer knows whether
    /// to keep going: 1 (CONTINUE) while the paned has no width yet, 0 (REMOVE) once set — or if the paned is
    /// gone / has no ratio. set_position pins `position-set`, so the next layout won't snap it back to 50/50.
    @discardableResult func tryRestorePanedRatio(_ paned: OpaquePointer?) -> gboolean {
        guard let paned, let (sid, _) = sessionPanes.first(where: { $0.value == paned }) else { return 0 }
        guard let ratio = store.session(withID: sid)?.splitRatio else { splitCaptureSuppressed.remove(sid); return 0 }
        let width = gtk_widget_get_width(W(paned))
        guard width > 0 else { return 1 }   // not laid out yet → keep retrying (capture stays suppressed)
        gtk_paned_set_position(paned, Int32(ratio * Double(width)))
        splitCaptureSuppressed.remove(sid)   // restore applied → user drags capture again
        return 0
    }

    /// Apply a control-driven `session.resize` ratio to the live GtkPaned and persist it. If the split is
    /// currently hidden or not laid out yet, the stored ratio is picked up the next time it is shown.
    func applySplitRatio(to session: Session) {
        store.save()
        guard let paned = sessionPanes[session.id], session.splitRatio != nil else { return }
        splitCaptureSuppressed.insert(session.id)
        if tryRestorePanedRatio(paned) != 0 {
            _ = g_timeout_add(50, restorePanedRatioTick, UnsafeMutableRawPointer(paned))
        }
    }

    private func removeSession(_ id: UUID) {
        splitCaptureSuppressed.remove(id)
        scratchSurfaces[id]?.teardown()
        scratchSurfaces[id] = nil
        if let frame = floatingOverlayFrames[id], let overlay = deckOverlay {
            gtk_overlay_remove_overlay(overlay, W(frame))
            floatingOverlayFrames[id] = nil
        }
        overlaySurfaces[id]?.teardown()
        overlaySurfaces[id] = nil
        splitSurfaces[id]?.teardown()
        splitSurfaces[id] = nil
        surfaces[id]?.teardown()
        if let stack = sessionStacks[id] { gtk_stack_remove(deck, W(stack)) }
        surfaces[id] = nil
        sessionPanes[id] = nil
        sessionStacks[id] = nil
    }

    private func showActive() {
        guard let active = store.activeSession else { return }
        active.id.uuidString.withCString { gtk_stack_set_visible_child_name(deck, $0) }
        updateFloatingOverlayVisibility(activeID: active.id)
        if active.overlayActive {
            overlaySurfaces[active.id]?.grabFocus()
        } else if active.scratchActive {
            scratchSurfaces[active.id]?.grabFocus()
        } else if active.splitFocused, let split = splitSurfaces[active.id] {
            split.grabFocus()
        } else {
            surfaces[active.id]?.grabFocus()
        }
        updateToggleIcons()
    }

    private func updateFloatingOverlayVisibility(activeID: UUID) {
        for (id, frame) in floatingOverlayFrames {
            let visible = id == activeID && (store.session(withID: id)?.overlayActive == true)
            gtk_widget_set_visible(W(frame), visible ? 1 : 0)
        }
    }

    /// Per-session OSC 9;4 progress: -1 = indeterminate, 0-100 = percent; absent = none (ephemeral).
    private var sessionProgress: [UUID: Int] = [:]

    /// A session reported agent progress (OSC 9;4). Store it and, if it's the focused session, reflect it
    /// in the window title (the Wayland-portable cue — there's no standard taskbar progress).
    func surfaceDidReportProgress(_ id: UUID, percent: Int?) {
        if let percent { sessionProgress[id] = percent } else { sessionProgress.removeValue(forKey: id) }
        if id == store.selectedSessionID { updateTitle() }
    }

    func updateTitle() {
        var title = store.activeSession?.displayName ?? "agterm"
        if let id = store.selectedSessionID, let p = sessionProgress[id] {
            title = (p < 0 ? "⋯ " : "\(p)% ") + title   // -1 = indeterminate spinner cue
        }
        title.withCString { gtk_window_set_title(WIN(window), $0) }
    }

    /// The installed monospace font families (Pango), sorted + de-duplicated — populates the Settings
    /// font picker. The GTK analogue of macOS's NSFontManager monospaced-families list.
    func monospaceFonts() -> [String] {
        guard let ctx = gtk_widget_get_pango_context(W(window)) else { return [] }
        var families: UnsafeMutablePointer<UnsafeMutablePointer<PangoFontFamily>?>?
        var count: Int32 = 0
        pango_context_list_families(ctx, &families, &count)
        defer { g_free(families) }
        var names: Set<String> = []
        for i in 0..<Int(count) {
            guard let fam = families?[i], pango_font_family_is_monospace(fam) != 0,
                  let c = pango_font_family_get_name(fam) else { continue }
            names.insert(String(cString: c))
        }
        return names.sorted()
    }

    /// A surface reported an OSC title / pwd; route it to the correct pane field (primary vs split)
    /// via the shared store so a split pane never clobbers the primary's, then refresh the title (and
    /// the sidebar row, whose displayName is focus-aware) when it affects the visible session.
    func sessionDidReportTitle(_ id: UUID, _ title: String, isSplit: Bool) {
        store.recordTitle(title, forSession: id, isSplit: isSplit)
        if id == store.selectedSessionID { updateTitle() }
        rebuildSidebar()
    }
    func sessionDidReportPwd(_ id: UUID, _ pwd: String, isSplit: Bool) {
        store.recordPwd(pwd, forSession: id, isSplit: isSplit)
        if id == store.selectedSessionID { updateTitle() }
        rebuildSidebar()
    }

    /// A surface reported its live font size (CELL_SIZE) — persist it on the session (debounced) so a
    /// ⌘+/⌘− zoom survives relaunch. No-op when the session isn't in this window's store.
    func sessionDidReportFontSize(_ id: UUID, _ size: Double) {
        store.setFontSize(id, size)
    }

    /// A pane gained keyboard focus: record which one so a split session's focus-aware displayName,
    /// title, and cwd follow it (the sidebar row + window title). Gated on `hasSplit` so a plain
    /// session's routine focus changes cause no work.
    func surfaceDidFocus(_ id: UUID, isSplit: Bool) {
        guard store.session(withID: id)?.hasSplit == true else { return }
        store.setPaneFocus(isSplit, forSession: id)
        if let s = store.session(withID: id) { updatePaneDim(s) }
        rebuildSidebar()
        if id == store.selectedSessionID { updateTitle() }
    }

    /// Dim the inactive split pane as a focus cue, using the shared `AppSettings.muteOpacity` strength.
    /// GTK has no per-pane wash layer like the macOS `paneDim` overlay, so this fades the whole inactive
    /// pane toward the window background; refine to a terminal-color wash if the appearance needs it.
    private func updatePaneDim(_ s: Session) {
        let strength = SettingsStore().load().inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength
        let dimmed = 1.0 - AppSettings.muteOpacity(strength: strength)
        if let main = surfaces[s.id]?.glArea {
            gtk_widget_set_opacity(W(main), s.isSplit && s.splitFocused ? dimmed : 1.0)
        }
        if let split = splitSurfaces[s.id]?.glArea {
            gtk_widget_set_opacity(W(split), s.isSplit && !s.splitFocused ? dimmed : 1.0)
        }
    }

    func rebuildSidebar() {
        updateAttentionButton()
        while let child = gtk_widget_get_first_child(W(sidebarBox)) {
            gtk_box_remove(cast(sidebarBox), child)
        }
        rowSession.removeAll()
        nameLabels.removeAll()
        workspaceDiscButtons.removeAll()
        workspaceListBoxes.removeAll()

        if store.sidebarMode == .flagged {
            appendSection("Flagged", store.flaggedSessions)
            if store.flaggedSessions.isEmpty {   // empty-state hint so the flagged view isn't blank
                if let hint = op(gtk_label_new("No flagged sessions.\nRight-click a session → Flag.")) {
                    gtk_label_set_justify(hint, GTK_JUSTIFY_CENTER)
                    gtk_widget_set_margin_top(W(hint), 24)
                    gtk_widget_add_css_class(W(hint), "dim-label")
                    gtk_box_append(cast(sidebarBox), W(hint))
                }
            }
        } else {
            // Focus pill: when a workspace is focused (tree collapsed to it), a clear-focus chip at the top.
            if let fid = store.focusedWorkspaceID, let ws = store.workspaces.first(where: { $0.id == fid }),
               let pill = op(gtk_button_new()) {
                "✕  \(ws.name)".withCString { gtk_button_set_label(cast(pill), $0) }
                gtk_widget_add_css_class(W(pill), "agterm-focus-pill")
                gtk_widget_set_margin_top(W(pill), 4)
                gtk_widget_set_margin_start(W(pill), 8); gtk_widget_set_margin_end(W(pill), 8)
                connect(pill, "clicked", unsafeBitCast(onClearFocusPill as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
                gtk_box_append(cast(sidebarBox), W(pill))
            }
            for ws in store.visibleWorkspaces { appendSection(ws.name, ws.sessions, workspace: ws.id) }
        }
    }

    private func appendSection(_ title: String, _ sessions: [Session], workspace: UUID? = nil) {
        // A real workspace header is a row: a disclosure triangle (collapse toggle) + a grid glyph + an
        // inline-rename GtkEditableLabel (double-click to edit), matching macOS's "▽ ⊞ Ameba". The flagged
        // section header is just a plain heading label.
        if let wsID = workspace, let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)) {
            "workspace-row".withCString { gtk_widget_set_name(W(row), $0) }   // stable automation id
            gtk_widget_set_margin_top(W(row), 8)
            gtk_widget_set_margin_start(W(row), 4)
            let collapsed = collapsedWorkspaceIDs.contains(wsID)
            if let disc = op(gtk_button_new_from_icon_name(collapsed ? "pan-end-symbolic" : "pan-down-symbolic")) {
                gtk_button_set_has_frame(BUTTON(disc), 0)
                gtk_widget_add_css_class(W(disc), "flat")
                workspaceDiscButtons[disc] = wsID
                connect(disc, "clicked", unsafeBitCast(onWorkspaceDisclosure as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(disc))
                gtk_box_append(cast(row), W(disc))
            }
            gtk_box_append(cast(row), W(op(gtk_image_new_from_icon_name("agterm-grid-symbolic"))))
            if let name = makeNameWidget(id: wsID, text: title, isWorkspace: true) {
                gtk_widget_add_css_class(W(name), "heading")
                gtk_box_append(cast(row), W(name))
            }
            // Right-click the workspace header -> a workspace context menu (rename / delete). The row is
            // both the popover parent and the workspace-id map key.
            workspaceDiscButtons[row] = wsID
            let wsRightClick = gtk_gesture_click_new()
            gtk_gesture_single_set_button(wsRightClick, 3)
            connect(wsRightClick, "pressed", unsafeBitCast(onWorkspaceRightClick as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), RAW(row))
            gtk_widget_add_controller(W(row), wsRightClick)
            // Drag the header to reorder workspaces (content "w:<id>"); the header also ACCEPTS a session
            // drop ("<id>" → move that session into this workspace). Mirrors the session-row drag/drop.
            let wdrag = gtk_drag_source_new()
            gtk_drag_source_set_actions(wdrag, GDK_ACTION_MOVE)
            connect(wdrag, "prepare", unsafeBitCast(onHeaderDragPrepare as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer?, to: GCallback.self))
            gtk_widget_add_controller(W(row), wdrag)
            let wdrop = gtk_drop_target_new(GType(64) /* G_TYPE_STRING */, GDK_ACTION_MOVE)
            connect(wdrop, "drop", unsafeBitCast(onHeaderDrop as @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean, to: GCallback.self))
            gtk_widget_add_controller(W(row), wdrop)
            gtk_box_append(cast(sidebarBox), W(row))
        } else if let header = op(gtk_label_new(title)) {
            gtk_label_set_xalign(header, 0)
            gtk_widget_add_css_class(W(header), "heading")
            gtk_widget_set_margin_top(W(header), 8)
            gtk_widget_set_margin_start(W(header), 8)
            gtk_box_append(cast(sidebarBox), W(header))
        }

        if let wsID = workspace, collapsedWorkspaceIDs.contains(wsID) { return }   // collapsed: header only

        guard let lb = op(gtk_list_box_new()) else { return }
        gtk_widget_add_css_class(W(lb), "navigation-sidebar")
        // Indent the session list under its workspace header (only in the tree view, not flagged).
        if workspace != nil { gtk_widget_set_margin_start(W(lb), 14) }
        gtk_list_box_set_selection_mode(lb, GTK_SELECTION_SINGLE)
        connect(lb, "row-activated", unsafeBitCast(onRowActivated as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        // Right-click a row -> a context menu (flag/rename/clear-status/close). The listbox is the
        // gesture's user_data so the handler can resolve which row was hit via get_row_at_y.
        let rightClick = gtk_gesture_click_new()
        gtk_gesture_single_set_button(rightClick, 3)
        connect(rightClick, "pressed", unsafeBitCast(onRowRightClick as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), RAW(lb))
        gtk_widget_add_controller(W(lb), rightClick)
        workspaceListBoxes.append(lb)

        for s in sessions {
            guard let row = makeRow(s) else { continue }
            gtk_list_box_append(lb, W(row))
            rowSession[row] = s.id
            if s.id == store.selectedSessionID { gtk_list_box_select_row(lb, GLBR(row)) }
        }
        gtk_box_append(cast(sidebarBox), W(lb))
    }

    /// A session row: name (expanding) + optional agent-status / flag glyph.
    private func makeRow(_ s: Session) -> OpaquePointer? {
        guard let row = op(gtk_list_box_row_new()), let box = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)) else { return nil }
        "session-row".withCString { gtk_widget_set_name(W(row), $0) }   // stable automation id (the a11y label stays the session name)
        // Leading session glyph (a terminal icon before the name, like the macOS rows).
        if let lead = op(gtk_image_new_from_icon_name("utilities-terminal-symbolic")) {
            gtk_widget_set_margin_start(W(lead), 6)
            gtk_box_append(cast(box), W(lead))
        }
        let flaggedView = store.sidebarMode == .flagged
        // Flagged view: a plain "name — workspace" label (no rename — that's the tree view's job). Tree
        // view: single-click selects (row-activated), double-click renames inline (makeNameWidget).
        let label = flaggedView ? op(gtk_label_new(store.flaggedRowLabel(for: s))) : makeNameWidget(id: s.id, text: s.displayName, isWorkspace: false)
        gtk_widget_set_hexpand(W(label), 1)
        gtk_widget_set_margin_top(W(label), 4)
        gtk_widget_set_margin_bottom(W(label), 4)
        gtk_widget_set_margin_start(W(label), 4)
        if flaggedView { gtk_label_set_xalign(label, 0) }
        gtk_box_append(cast(box), W(label))
        if let icon = Self.statusIcon(s.agentIndicator.status), let glyph = op(gtk_image_new_from_icon_name(icon)) {
            // tint the glyph by status (active/completed/blocked) so the cue reads at a glance.
            if let cls = Self.statusColorClass(s.agentIndicator.status) { gtk_widget_add_css_class(W(glyph), cls) }
            // a blinking indicator (agent in-progress) pulses via the .agterm-blink CSS animation.
            if s.agentIndicator.blink { gtk_widget_add_css_class(W(glyph), "agterm-blink") }
            gtk_box_append(cast(box), W(glyph))
        }
        if s.flagged, !flaggedView {   // the star is redundant in the flagged-only view
            gtk_box_append(cast(box), W(op(gtk_image_new_from_icon_name("starred-symbolic"))))
        }
        if s.unseenCount > 0, badgeEnabled, let badge = op(gtk_label_new(nil)) {
            // Pango markup gives a colored count pill without a CSS provider (version-robust). Cleared
            // by selectSession (core zeroes unseenCount; the controller re-renders the row).
            let text = s.unseenCount > 99 ? "99+" : "\(s.unseenCount)"
            "<span background=\"#cc3333\" foreground=\"white\"> \(text) </span>".withCString { gtk_label_set_markup(badge, $0) }
            gtk_box_append(cast(box), W(badge))
        }
        gtk_widget_set_margin_end(W(box), 6)
        gtk_list_box_row_set_child(GLBR(row), W(box))
        // Drag-to-reorder (tree mode only; flagged mode disables it, matching macOS). The row carries its
        // session id as a string; the drop target resolves the move via the shared SidebarDrop.
        if !flaggedView {
            let drag = gtk_drag_source_new()
            gtk_drag_source_set_actions(drag, GDK_ACTION_MOVE)
            connect(drag, "prepare", unsafeBitCast(onRowDragPrepare as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer?, to: GCallback.self))
            gtk_widget_add_controller(W(row), drag)
            let drop = gtk_drop_target_new(GType(64) /* G_TYPE_STRING */, GDK_ACTION_MOVE)
            connect(drop, "drop", unsafeBitCast(onRowDrop as @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean, to: GCallback.self))
            gtk_widget_add_controller(W(row), drop)
        }
        return row
    }

    private static func statusIcon(_ s: AgentStatus) -> String? {
        switch s {
        case .idle: return nil
        case .active: return "content-loading-symbolic"
        case .completed: return "emblem-ok-symbolic"
        case .blocked: return "dialog-warning-symbolic"
        }
    }

    /// The CSS class that tints the agent-status glyph by status (symbolic icons follow `color`):
    /// active=blue, completed=green, blocked=amber — the semantic cue the macOS glyph colors give.
    private static func statusColorClass(_ s: AgentStatus) -> String? {
        switch s {
        case .idle: return nil
        case .active: return "agterm-status-active"
        case .completed: return "agterm-status-completed"
        case .blocked: return "agterm-status-blocked"
        }
    }

    func updateAttentionButton() {
        guard let button = attentionButton else { return }
        let enabled = SettingsStore().load().attentionButtonEnabled ?? false
        gtk_widget_set_visible(W(button), enabled ? 1 : 0)
        let sessions = store.attentionSessions
        gtk_widget_set_sensitive(W(button), sessions.isEmpty ? 0 : 1)
        let hasBlocked = sessions.contains { $0.agentIndicator.status == .blocked }
        gtk_button_set_icon_name(BUTTON(button), hasBlocked ? "dialog-warning-symbolic" : "emblem-important-symbolic")
    }

    func session(forRow row: OpaquePointer?) -> UUID? {
        guard let row else { return nil }
        return rowSession[row]
    }

    /// Apply a session row drag-and-drop: drop `source` ON the `target` row → land it just after the
    /// target (intra- or cross-workspace), via the shared host-free index arithmetic. No-op math + the
    /// post-removal index live in `agtermCore.SidebarDrop`; this is the GTK→store glue.
    func handleSessionDrop(source: UUID, onto target: UUID) {
        guard source != target,
              let src = store.sessionLocation(ofSession: source),
              let tgt = store.sessionLocation(ofSession: target) else { return }
        let dropTarget = SidebarDrop.SessionDropTarget.sessionRow(workspace: tgt.workspace, sessionIndex: tgt.index, sessionCount: tgt.count)
        guard let res = SidebarDrop.resolveSession(sourceWorkspace: src.workspace, sourceIndex: src.index,
                                                   target: dropTarget, childIndex: SidebarDrop.onItemIndex) else { return }
        store.moveSession(source, toWorkspace: res.workspace, at: res.destination)
        reconcile()
    }

    /// The workspace id of a header row (drag source / drop target lookup).
    func workspaceForHeader(_ header: OpaquePointer?) -> UUID? { header.flatMap { workspaceDiscButtons[$0] } }

    /// Drop a workspace header ON another → reorder via the shared SidebarDrop index arithmetic.
    func handleWorkspaceDrop(source: UUID, onto target: UUID) {
        guard source != target,
              let s = store.workspaces.firstIndex(where: { $0.id == source }),
              let t = store.workspaces.firstIndex(where: { $0.id == target }),
              let res = SidebarDrop.resolveWorkspace(sourceIndex: s, count: store.workspaces.count, childIndex: t) else { return }
        store.moveWorkspace(source, at: res.destination)
        rebuildSidebar()
    }

    /// Drop a session ON a workspace header → move that session into the workspace.
    func handleSessionToWorkspace(session: UUID, workspace: UUID) {
        guard store.session(withID: session) != nil else { return }
        store.moveSession(session, toWorkspace: workspace)
        reconcile()
    }

    // MARK: - Row context menu

    /// Show the right-click context menu for the row under `y` in `listBox`. Reuses the controller
    /// actions (flag/rename/clear-status/close) via a stored target session so the C button handlers
    /// need no per-button user_data.
    func showRowContextMenu(listBox: OpaquePointer, x: Double, y: Double) {
        guard let rowPtr = gtk_list_box_get_row_at_y(listBox, Int32(y)),
              let sid = rowSession[OpaquePointer(rowPtr)] else { return }
        contextMenuSession = sid
        dismissContextMenu()   // tear down any previous popover before reparenting a new one
        guard let popover = op(gtk_popover_new()) else { return }
        contextMenuPopover = popover
        gtk_widget_set_parent(W(popover), W(listBox))
        var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(POPOVER(popover), &rect)
        gtk_popover_set_position(POPOVER(popover), GTK_POS_RIGHT)
        let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        let session = store.session(withID: sid)
        addContextButton(box, session?.flagged == true ? "Unflag" : "Flag",
                         unsafeBitCast(onCtxFlag as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        addContextButton(box, "Rename",
                         unsafeBitCast(onCtxRename as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        if session?.agentIndicator.status != AgentStatus.idle {
            addContextButton(box, "Clear Status",
                             unsafeBitCast(onCtxClearStatus as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        }
        addContextButton(box, "Focus Workspace",
                         unsafeBitCast(onCtxFocus as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        // Move to another workspace: one button per OTHER workspace, keyed to its id (stored-target map).
        if let cur = store.workspace(forSession: sid) {
            for ws in store.workspaces where ws.id != cur.id {
                if let btn = op(gtk_button_new_with_label("Move to \(ws.name)")) {
                    gtk_button_set_has_frame(BUTTON(btn), 0)
                    gtk_widget_set_halign(W(btn), GTK_ALIGN_FILL)
                    contextMoveTargets[btn] = ws.id
                    connect(btn, "clicked", unsafeBitCast(onCtxMove as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(btn))
                    gtk_box_append(cast(box), W(btn))
                }
            }
        }
        addContextButton(box, "Close Session",
                         unsafeBitCast(onCtxClose as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        gtk_popover_set_child(POPOVER(popover), W(box))
        gtk_popover_popup(POPOVER(popover))
    }

    private func addContextButton(_ box: OpaquePointer?, _ label: String, _ handler: GCallback?) {
        guard let button = op(gtk_button_new_with_label(label)) else { return }
        gtk_button_set_has_frame(BUTTON(button), 0)   // flat, menu-row look
        gtk_widget_set_halign(W(button), GTK_ALIGN_FILL)
        connect(button, "clicked", handler)
        gtk_box_append(cast(box), W(button))
    }

    /// Fully tear down the context-menu popover (popdown + unparent), so a following `rebuildSidebar`
    /// can destroy the parent listbox without orphaning it.
    private func dismissContextMenu() {
        if let popover = contextMenuPopover {
            gtk_popover_popdown(POPOVER(popover))
            gtk_widget_unparent(W(popover))
            contextMenuPopover = nil
        }
        contextMoveTargets.removeAll()   // the move buttons die with the popover
    }

    /// Context-menu "Focus Workspace": toggle the focus filter on the target session's workspace.
    func contextFocusWorkspace() {
        guard let id = contextMenuSession, let ws = store.workspace(forSession: id) else { return }
        dismissContextMenu()
        focusWorkspace(store.focusedWorkspaceID == ws.id ? nil : ws.id)
    }

    /// Context-menu "Move to <ws>": move the target session into the workspace keyed to the clicked button.
    func contextMoveToWorkspace(_ data: gpointer?) {
        guard let data, let ws = contextMoveTargets[OpaquePointer(data)], let id = contextMenuSession else { return }
        dismissContextMenu()
        store.moveSession(id, toWorkspace: ws)
        reconcile()
    }

    func contextFlag() {
        guard let id = contextMenuSession, let s = store.session(withID: id) else { return }
        dismissContextMenu()
        store.setFlag(!s.flagged, forSession: id)
        rebuildSidebar()
    }
    func contextRename() {
        guard let id = contextMenuSession else { return }
        dismissContextMenu()
        selectSession(id)
        startRenameActive()
    }

    /// Right-click on a workspace header → a context menu (Rename / Delete), mirroring the row menu.
    /// `rowData` is the header row (the gesture's widget + the workspace-id map key).
    func showWorkspaceContextMenu(_ rowData: gpointer?, x: Double, y: Double) {
        guard let rowData, let wsID = workspaceDiscButtons[OpaquePointer(rowData)] else { return }
        let parent = OpaquePointer(rowData)
        contextMenuWorkspace = wsID
        dismissContextMenu()
        guard let popover = op(gtk_popover_new()) else { return }
        contextMenuPopover = popover
        gtk_widget_set_parent(W(popover), W(parent))
        var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(POPOVER(popover), &rect)
        gtk_popover_set_position(POPOVER(popover), GTK_POS_RIGHT)
        let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        addContextButton(box, "Rename", unsafeBitCast(onCtxWorkspaceRename as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        if store.canRemoveWorkspace {
            addContextButton(box, "Delete Workspace", unsafeBitCast(onCtxWorkspaceDelete as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        }
        gtk_popover_set_child(POPOVER(popover), W(box))
        gtk_popover_popup(POPOVER(popover))
    }
    func contextWorkspaceRename() {
        guard let id = contextMenuWorkspace else { return }
        dismissContextMenu()
        beginRename(id: id, isWorkspace: true)
    }
    func contextWorkspaceDelete() {
        guard let id = contextMenuWorkspace, store.canRemoveWorkspace else { return }
        dismissContextMenu()
        // Confirm before deleting a workspace + all its sessions (matches macOS's destructive-action alert).
        pendingDeleteWorkspace = id
        let ws = store.workspaces.first(where: { $0.id == id })
        let heading = "Delete Workspace?"
        let body = DeletePrompt.workspaceMessage(name: ws?.name ?? "this workspace", sessions: ws?.sessions.count ?? 0)
        let dialog = OpaquePointer(heading.withCString { h in body.withCString { b in adw_alert_dialog_new(h, b) } })
        "cancel".withCString { i in "Cancel".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "delete".withCString { i in "Delete".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "delete".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_DESTRUCTIVE) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onDeleteWorkspaceResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }

    /// The delete-confirm dialog responded — remove the workspace only on the explicit "delete" response.
    func confirmWorkspaceDelete(_ response: String) {
        defer { pendingDeleteWorkspace = nil }
        guard response == "delete", let id = pendingDeleteWorkspace, store.canRemoveWorkspace else { return }
        store.removeWorkspace(id)
        reconcile()
    }

    /// Confirm + delete a window (the whole bundle of workspaces/sessions). Destructive AdwAlertDialog,
    /// mirroring the workspace delete. Keep-at-least-one is enforced by `canRemoveWindow`.
    func confirmDeleteWindow(_ id: UUID) {
        guard gLibrary.canRemoveWindow else { return }
        pendingDeleteWindow = id
        let name = gLibrary.windows.first(where: { $0.id == id })?.name ?? "this window"
        let dialog = OpaquePointer("Delete Window?".withCString { h in DeletePrompt.windowMessage(name: name).withCString { b in adw_alert_dialog_new(h, b) } })
        "cancel".withCString { i in "Cancel".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "delete".withCString { i in "Delete".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "delete".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_DESTRUCTIVE) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onDeleteWindowResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }

    func confirmWindowDelete(_ response: String) {
        defer { pendingDeleteWindow = nil }
        guard response == "delete", let id = pendingDeleteWindow, gLibrary.canRemoveWindow else { return }
        if let ctl = gWindows[id] {
            ctl.confirmedClose = true
            gtk_window_close(WIN(ctl.windowPointer))   // tear down if open; delete confirmation already happened.
        }
        gLibrary.removeWindow(id)
    }

    /// Rename a window via an AdwAlertDialog carrying a GtkEntry (windows have no inline sidebar row).
    func renameWindowDialog(_ id: UUID) {
        pendingRenameWindow = id
        let cur = gLibrary.windows.first(where: { $0.id == id })?.name ?? ""
        let dialog = OpaquePointer("Rename Window".withCString { adw_alert_dialog_new($0, nil) })
        let entry = OpaquePointer(gtk_entry_new())
        cur.withCString { gtk_editable_set_text(entry, $0) }
        pendingRenameEntry = entry
        adw_alert_dialog_set_extra_child(cast(dialog), W(entry))
        "cancel".withCString { i in "Cancel".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "rename".withCString { i in "Rename".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "rename".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_SUGGESTED) }
        "rename".withCString { adw_alert_dialog_set_default_response(cast(dialog), $0) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onRenameWindowResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }

    func confirmWindowRename(_ response: String) {
        defer { pendingRenameWindow = nil; pendingRenameEntry = nil }
        guard response == "rename", let id = pendingRenameWindow, let entry = pendingRenameEntry,
              let cstr = gtk_editable_get_text(entry) else { return }
        let name = String(cString: cstr).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        gLibrary.renameWindow(id, to: name)
        if id == windowID { updateTitle() }   // the current window's title bar reflects the new name
    }
    func contextClearStatus() {
        guard let id = contextMenuSession else { return }
        dismissContextMenu()
        store.setAgentIndicator(AgentIndicator(), forSession: id)
        rebuildSidebar()
    }
    func contextCloseSession() {
        guard let id = contextMenuSession else { return }
        dismissContextMenu()
        closeSession(id)
    }
}

@inline(__always) func GLBR(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkListBoxRow>? { p.map { UnsafeMutablePointer($0) } }

// MARK: - GTK trampolines

private let onWindowActive: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let ctl = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
        if gtk_window_is_active(WIN(ctl.windowPointer)) != 0 { ctl.becameFrontmost() }
    }
}
private let onWindowCloseRequest: @convention(c) (OpaquePointer?, gpointer?) -> gboolean = { _, data in
    guard let data else { return 0 }
    let ctl = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
    // Confirm before quitting (last window). If allowed, tear down + allow; else prevent (dialog shows).
    let allow = MainActor.assumeIsolated { ctl.windowShouldClose() }
    guard allow else { return 1 }
    MainActor.assumeIsolated { ctl.windowWillClose() }
    return 0
}
/// AdwAlertDialog "response" for the quit-confirm: re-issue the close on "quit".
private let onQuitResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { gController?.confirmQuit(id) }
}
private let onNewSession: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.newSession() }
}
private let onNewWorkspace: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.newWorkspace() }
}
private let onSidebarToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleSidebar() }
}
private let onSplitToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleSplit() }
}
private let onScratchToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleScratch() }
}
private let onQuickToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleQuick() }
}
private let onNewWindow: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.openNewWindow() }
}
private let onFlaggedToggle: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.toggleFlaggedView() }
}
private let onAttentionButton: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.showAttentionPalette() }
}
private let onRowActivated: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, row, _ in
    MainActor.assumeIsolated {
        if let id = gController?.session(forRow: row) { gController?.selectSession(id) }
    }
}
private let onRowRightClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, _, x, y, data in
    guard let data else { return }
    MainActor.assumeIsolated { gController?.showRowContextMenu(listBox: OpaquePointer(data), x: x, y: y) }
}
private let onWorkspaceDisclosure: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { gController?.toggleWorkspaceCollapse(data) }
}
/// GtkFileDialog.select_folder completion: extract the chosen folder path and open a session there.
/// (`source` is the GtkFileDialog; `result` is the GAsyncResult to finish.)
/// GtkDragSource "prepare" for a session row: hand off the row's session id as a string content provider.
private let onRowDragPrepare: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer? = { source, _, _, _ in
    // Resolve the row's session id under the main actor, returning the Sendable String; build the
    // (non-Sendable) GdkContentProvider OUTSIDE the isolated block — both still run on the GTK main thread.
    let uuid: String? = MainActor.assumeIsolated {
        guard let w = gtk_event_controller_get_widget(source) else { return nil }
        return gController?.session(forRow: OpaquePointer(w))?.uuidString
    }
    guard let uuid else { return nil }
    var v = GValue()
    _ = g_value_init(&v, GType(64))   // G_TYPE_STRING
    uuid.withCString { g_value_set_string(&v, $0) }
    let provider = gdk_content_provider_new_for_value(&v)
    g_value_unset(&v)
    return provider.map { OpaquePointer($0) }
}
/// GtkDropTarget "drop" on a session row: read the dragged session id and apply the reorder.
private let onRowDrop: @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { target, value, _, _, _ in
    MainActor.assumeIsolated {
        guard let value, let cstr = g_value_get_string(value),
              let w = gtk_event_controller_get_widget(target),
              let targetSid = gController?.session(forRow: OpaquePointer(w)),
              let sourceSid = UUID(uuidString: String(cString: cstr)) else { return 0 }   // "w:…" → nil → ignored
        gController?.handleSessionDrop(source: sourceSid, onto: targetSid)
        return 1
    }
}
/// GtkDragSource "prepare" for a workspace HEADER: hand off the workspace id as "w:<uuid>".
private let onHeaderDragPrepare: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer? = { source, _, _, _ in
    let payload: String? = MainActor.assumeIsolated {
        guard let w = gtk_event_controller_get_widget(source) else { return nil }
        return gController?.workspaceForHeader(OpaquePointer(w)).map { "w:\($0.uuidString)" }
    }
    guard let payload else { return nil }
    var v = GValue()
    _ = g_value_init(&v, GType(64))   // G_TYPE_STRING
    payload.withCString { g_value_set_string(&v, $0) }
    let provider = gdk_content_provider_new_for_value(&v)
    g_value_unset(&v)
    return provider.map { OpaquePointer($0) }
}
/// GtkDropTarget "drop" on a workspace HEADER: a "w:<id>" reorders workspaces, a bare "<id>" moves that
/// session into this workspace.
private let onHeaderDrop: @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { target, value, _, _, _ in
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
/// AdwAlertDialog "response" signal for the delete-workspace confirm: dispatch the response id string.
private let onDeleteWorkspaceResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { gController?.confirmWorkspaceDelete(id) }
}
private let onDeleteWindowResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { gController?.confirmWindowDelete(id) }
}
private let onRenameWindowResponse: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { gController?.confirmWindowRename(id) }
}
private let onClearFocusPill: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.focusWorkspace(nil) }
}
private let onDirectoryChosen: @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, gpointer?) -> Void = { source, result, _ in
    // source is the GtkFileDialog (as a GObject); finish takes it as the dialog OpaquePointer.
    guard let file = gtk_file_dialog_select_folder_finish(source.map { OpaquePointer($0) }, result, nil) else { return }   // nil = cancelled
    guard let cpath = g_file_get_path(file) else { return }
    let path = String(cString: cpath)
    g_free(cpath)
    MainActor.assumeIsolated { gController?.createSessionInDirectory(path) }
}
private let onCtxFlag: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextFlag() }
}
private let onCtxFocus: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextFocusWorkspace() }
}
private let onCtxMove: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { gController?.contextMoveToWorkspace(data) }
}
private let onCtxRename: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextRename() }
}
private let onCtxClearStatus: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextClearStatus() }
}
private let onCtxClose: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextCloseSession() }
}
private let onMenuButton: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.showPalette() }
}
private let onNameDoubleClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, nPress, _, _, data in
    guard nPress == 2 else { return }   // single click selects (row-activated); double click renames
    MainActor.assumeIsolated { gController?.beginRenameFromLabel(data) }
}
private let onRenameCommit: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { gController?.commitInlineRename(data) }
}
private let onRenameKey: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { _, keyval, _, _, _ in
    guard keyval == 0xFF1B else { return 0 }   // Escape
    MainActor.assumeIsolated { gController?.cancelInlineRename() }
    return 1
}
private let onWorkspaceRightClick: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, _, x, y, data in
    MainActor.assumeIsolated { gController?.showWorkspaceContextMenu(data, x: x, y: y) }
}
private let onCtxWorkspaceRename: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextWorkspaceRename() }
}
private let onCtxWorkspaceDelete: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.contextWorkspaceDelete() }
}
private let onPanedPosition: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { paned, _, _ in
    MainActor.assumeIsolated { gController?.capturePanedRatio(paned) }
}
private let restorePanedRatioTick: @convention(c) (gpointer?) -> gboolean = { data in
    MainActor.assumeIsolated { gController?.tryRestorePanedRatio(data.map { OpaquePointer($0) }) ?? 0 }
}

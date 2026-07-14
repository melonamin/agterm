// Command palette (Ctrl+Shift+P): a modal GtkSearchEntry + GtkListBox of actions,
// fuzzy-filtered via agtermCore.fuzzyScore. Each action calls a thin AppController
// method (the shared controller). Enter runs the selected match; Esc closes.
import CGtk
import agtermCore

@MainActor
extension AppController {
    private func paletteActionList() -> [(String, () -> Void)] {
        // The fixed commands + their titles come from the shared PaletteCommand catalog; this maps each
        // to its Linux closure. The switch is EXHAUSTIVE, so adding a catalog case fails to compile until
        // it's wired here — the compiler is the keep-in-sync check.
        // Each fixed command shows its current keybind (kitty syntax) as a suffix when one resolves — the
        // palette-row "shortcut" widening. Searching matches the suffix too, so you can find by chord.
        // Omit fixed commands that would be no-ops in the current UI state (shared visibility predicates).
        let activeSession = store.selectedSessionID.flatMap { store.session(withID: $0) }
        let paletteContext = PaletteContext(canRemoveWorkspace: store.canRemoveWorkspace,
                                            hasFlaggedSessions: !store.flaggedSessions.isEmpty,
                                            sidebarShowsWorkspaceTree: store.sidebarMode == .tree,
                                            sidebarShowsFlaggedOnly: store.sidebarMode == .flagged,
                                            activeSessionFlagged: activeSession?.flagged ?? false,
                                            hasFocusedWorkspace: store.focusedWorkspaceID != nil,
                                            activeSessionHasSplit: activeSession?.hasSplit ?? false,
                                            hasPendingClose: store.pendingCloseSummary != nil,
                                            hasRecentClosed: !library.recentClosedItems.isEmpty)
        var items: [(String, () -> Void)] = PaletteCommand.allCases.filter { $0.isVisible(in: paletteContext) }.map { cmd in
            let entry = Self.entry(for: cmd)
            let chord = entry.builtin.flatMap { a in resolvedBuiltinChords.first(where: { $0.value == a })?.key }
            let suffix = chord.map { "   \($0.displayString)" } ?? ""
            return (cmd.title + suffix, entry.run)
        }
        // Open Directory… (Linux exposes it via the palette; macOS has it in the File menu).
        items.append(("Open Directory…", { gController?.openDirectory() }))
        // Preferences… (the Linux Settings surface; macOS uses the Settings scene / Cmd+,).
        items.append(("Preferences…", { gController?.showSettings() }))
        items.append(("Manage Integrations…", { gController?.showSettings(page: .integrations) }))
        items.append(("Keyboard Shortcuts", { gController?.showKeyboardShortcuts() }))
        items.append(("About agterm", { gController?.showAbout() }))
        // Linux has no global macOS-style Edit menu; expose the same terminal actions in the command palette.
        items.append(("Copy Selection", { gController?.activeSurface()?.performBindingAction("copy_to_clipboard") }))
        items.append(("Paste", { gController?.activeSurface()?.performBindingAction("paste_from_clipboard") }))
        items.append(("Select All", { gController?.activeSurface()?.performBindingAction("select_all") }))
        // Dynamic: switch to (open/raise) any other window — the Linux window-menu equivalent. New Window
        // is a fixed command above; rename/delete live on the window itself.
        for w in gLibrary.windows where w.id != windowID {
            let target = w.id
            items.append(("Switch to Window: \(w.name)", { openWindow(target) }))
            items.append(("Rename Window: \(w.name)", { gController?.renameWindowDialog(target) }))
            if gLibrary.canRemoveWindow {
                items.append(("Delete Window: \(w.name)", { gController?.confirmDeleteWindow(target) }))
            }
        }
        // Dynamic: move the active session to any OTHER workspace.
        if let sid = store.selectedSessionID, let current = store.workspace(forSession: sid) {
            for ws in store.workspaces where ws.id != current.id {
                let target = ws.id
                items.append(("Move Session to \(ws.name)", { gController?.moveActiveSession(to: target) }))
            }
        }
        // Dynamic: custom shell commands from keymap.conf (run via the palette; built-in chord dispatch
        // is a separate item).
        for cmd in (gController?.loadKeymapCommands().commands ?? []) {
            let command = cmd
            items.append((cmd.name + "  (custom)", { gController?.runCustomCommand(command) }))
        }
        // Dynamic: focus a single workspace, or clear an active focus.
        if store.focusedWorkspaceID != nil {
            items.append(("Clear Workspace Focus", { gController?.focusWorkspace(nil) }))
        } else if store.workspaces.count > 1 {
            for ws in store.workspaces {
                let target = ws.id
                items.append(("Focus Workspace \(ws.name)", { gController?.focusWorkspace(target) }))
            }
        }
        return items
    }

    /// The built-in action a palette command maps to (for showing its keybind; nil = palette-only, no
    /// rebindable built-in) PAIRED with its Linux closure. ONE exhaustive switch: adding a catalog case
    /// fails to compile until it's wired here, so the compiler keeps the palette in sync with the shared
    /// catalog — and the two halves can't drift from each other.
    private static func entry(for cmd: PaletteCommand) -> (builtin: BuiltinAction?, run: () -> Void) {
        switch cmd {
        case .newSession: return (.newSession, { gController?.newSession() })
        case .newWorkspace: return (.newWorkspace, { gController?.newWorkspace() })
        case .openDirectory: return (.openDirectory, { gController?.openDirectory() })
        case .renameSession: return (.renameSession, { gController?.startRenameActive() })
        case .renameWorkspace: return (.renameWorkspace, { if let ws = gController?.store.currentWorkspaceID { gController?.beginRename(id: ws, isWorkspace: true) } })
        case .closeSession: return (.closeSession, { if let id = gController?.store.selectedSessionID { gController?.requestCloseSession(id) } })
        case .reopenRecent: return (.reopenRecent, { gController?.reopenRecentClosed() })
        case .undoClose: return (.undoClose, { gController?.undoPendingClose() })
        case .clearStatus: return (.clearStatus, { gController?.clearActiveStatus() })
        case .previousSession: return (.previousSession, { gController?.navigate(.previous) })
        case .nextSession: return (.nextSession, { gController?.navigate(.next) })
        case .previousAttentionSession: return (.previousAttentionSession, { gController?.navigate(.previousAttention) })
        case .nextAttentionSession: return (.nextAttentionSession, { gController?.navigate(.nextAttention) })
        case .firstSession: return (.firstSession, { gController?.navigate(.first) })
        case .lastSession: return (.lastSession, { gController?.navigate(.last) })
        case .showAttention: return (.showAttention, { gController?.showAttentionPalette() })
        case .toggleSplit: return (.toggleSplit, { gController?.toggleSplit() })
        case .toggleScratch: return (.toggleScratch, { gController?.toggleScratch() })
        case .toggleTerminalZoom: return (.toggleTerminalZoom, { gController?.toggleTerminalZoom() })
        case .dashboard: return (.dashboard, { gController?.toggleDashboard() })
        case .toggleSidebar: return (.toggleSidebar, { gController?.toggleSidebar() })
        case .toggleFlag: return (.toggleFlag, { gController?.toggleFlagActive() })
        case .focusWorkspace: return (.focusWorkspace, { gController?.focusActiveWorkspace() })
        case .find: return (.toggleSearch, { gController?.toggleSearch() })
        case .quickTerminal: return (.quickTerminal, { gController?.toggleQuick() })
        case .toggleFullscreen: return (.toggleFullscreen, { gController?.toggleWindowFullscreen() })
        case .increaseFontSize: return (.increaseFontSize, { gController?.activeSurface()?.performBindingAction(FontBindingAction.increase) })
        case .decreaseFontSize: return (.decreaseFontSize, { gController?.activeSurface()?.performBindingAction(FontBindingAction.decrease) })
        case .resetFontSize: return (.resetFontSize, { gController?.activeSurface()?.performBindingAction(FontBindingAction.reset) })
        case .selectTheme: return (.selectTheme, { gController?.showThemePicker() })
        case .deleteWorkspace: return (.deleteWorkspace, { if let ws = gController?.store.currentWorkspaceID { gController?.store.removeWorkspace(ws); gController?.reconcile() } })
        case .toggleFlaggedView: return (.toggleFlaggedView, { gController?.toggleFlaggedView() })
        case .focusLeftPane: return (.focusLeftPane, { gController?.focusPane(left: true) })
        case .focusRightPane: return (.focusRightPane, { gController?.focusPane(left: false) })
        // palette-only (no rebindable built-in)
        case .expandWorkspaces: return (nil, { gController?.expandWorkspaces() })
        case .collapseWorkspaces: return (nil, { gController?.collapseOtherWorkspaces() })
        case .editKeymap: return (nil, { gController?.editKeymap() })
        case .reloadKeymap: return (nil, { _ = gController?.reloadKeymapDiagnostics() })
        case .editGhosttyConfig: return (nil, { gController?.editGhosttyConfig() })
        case .reloadConfig: return (nil, { gController?.reloadConfig() })
        case .clearFlagged: return (nil, { gController?.clearFlagged() })
        case .clearFocus: return (nil, { gController?.focusWorkspace(nil) })
        }
    }

    /// Jump to a session by fuzzy name (⌃P) — the session analogue of the action palette (⌃⇧P).
    func showSessionPalette() { showPalette(sessions: true) }

    /// Jump to a session that needs attention, matching the shared `show_attention` built-in action.
    func showAttentionPalette() { showPalette(attention: true) }

    /// The sessions across every workspace as palette entries (label = "name — workspace"), each
    /// selecting that session. Mirrors the macOS ⌃P session switcher.
    private func sessionPaletteList() -> [(String, () -> Void)] {
        store.navigableSessions.map { s in
            let ws = store.workspace(forSession: s.id)?.name ?? ""
            return ("\(s.displayName)  —  \(ws)", { gController?.selectSession(s.id) })
        }
    }

    private func attentionPaletteList() -> [(String, () -> Void)] {
        store.attentionSessions.map { s in
            let ws = store.workspace(forSession: s.id)?.name ?? ""
            return ("\(s.displayName)  —  \(ws)", { gController?.selectSession(s.id) })
        }
    }

    func showPalette(sessions: Bool = false, attention: Bool = false) {
        if paletteWindow != nil { closePalette(); return }   // re-invoking toggles the palette closed
        guard let win = op(gtk_window_new()) else { return }
        paletteWindow = win
        suppressAutoFollow()
        connect(win, "destroy", unsafeBitCast(onPaletteDestroyed, to: GCallback.self),
                Unmanaged.passRetained(self).toOpaque())
        gtk_window_set_transient_for(WIN(win), WIN(windowPointer))
        gtk_window_set_modal(WIN(win), 1)
        let title = attention ? "Go to Attention" : (sessions ? "Go to Session" : "Command Palette")
        title.withCString { gtk_window_set_title(WIN(win), $0) }
        gtk_window_set_default_size(WIN(win), 480, 360)

        let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        let entry = op(gtk_search_entry_new())
        connect(entry, "search-changed", unsafeBitCast(onPaletteSearch as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        connect(entry, "activate", unsafeBitCast(onPaletteActivate as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        gtk_box_append(cast(box), W(entry))

        let scroller = op(gtk_scrolled_window_new())
        gtk_widget_set_vexpand(W(scroller), 1)
        let lb = op(gtk_list_box_new())
        paletteList = lb
        "command-palette".withCString { gtk_widget_set_name(W(lb), $0) }   // automation id
        connect(lb, "row-activated", unsafeBitCast(onPaletteRow as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        gtk_scrolled_window_set_child(scroller, W(lb))
        gtk_box_append(cast(box), W(scroller))
        gtk_window_set_child(WIN(win), W(box))

        let kc = gtk_event_controller_key_new()
        // CAPTURE phase so Esc/arrows reach us BEFORE the focused search entry consumes them — otherwise
        // the entry's own Esc just clears the search text instead of closing the palette.
        gtk_event_controller_set_propagation_phase(kc, GTK_PHASE_CAPTURE)
        connect(kc, "key-pressed", unsafeBitCast(onPaletteKey as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self))
        gtk_widget_add_controller(W(win), kc)

        paletteAll = attention ? attentionPaletteList() : (sessions ? sessionPaletteList() : paletteActionList())
        filterPalette("")
        gtk_window_present(WIN(win))
        _ = gtk_widget_grab_focus(W(entry))
    }

    func filterPalette(_ query: String) {
        guard let lb = paletteList else { return }
        gtk_list_box_remove_all(lb)
        if query.isEmpty {
            paletteItems = paletteAll.sorted { $0.0.lowercased() < $1.0.lowercased() }   // empty query → alphabetical
        } else {
            // shared ranking seam (lower-is-better, best first, alpha tie-break) — index 0 is
            // auto-selected below, so the best match is what Enter runs.
            paletteItems = fuzzyRank(query: query, items: paletteAll, keys: { [$0.0] })
        }
        for item in paletteItems {
            guard let row = op(gtk_list_box_row_new()) else { continue }
            let label = op(gtk_label_new(item.0))
            gtk_label_set_xalign(label, 0)
            gtk_widget_set_margin_top(W(label), 6); gtk_widget_set_margin_bottom(W(label), 6)
            gtk_widget_set_margin_start(W(label), 10)
            gtk_list_box_row_set_child(GLBR(row), W(label))
            gtk_list_box_append(lb, W(row))
        }
        if let first = gtk_list_box_get_row_at_index(lb, 0) { gtk_list_box_select_row(lb, first) }
        if let vadj = paletteVadjustment() { gtk_adjustment_set_value(vadj, 0) }   // reset scroll to top on re-filter
    }

    func runPaletteSelected() {
        guard let lb = paletteList, let row = gtk_list_box_get_selected_row(lb) else { return }
        runPaletteIndex(Int(gtk_list_box_row_get_index(row)))
    }

    func runPaletteRow(_ row: OpaquePointer?) {
        guard let row else { return }
        runPaletteIndex(Int(gtk_list_box_row_get_index(GLBR(row))))
    }

    private func runPaletteIndex(_ idx: Int) {
        guard idx >= 0, idx < paletteItems.count else { return }
        let run = paletteItems[idx].1
        closePalette()
        run()
    }

    func closePalette() {
        guard let win = paletteWindow else { return }
        paletteWindow = nil
        paletteList = nil
        paletteItems = []
        resumeAutoFollow()
        gtk_window_destroy(WIN(win))
    }

    func paletteWasDestroyed() {
        guard paletteWindow != nil else { return }
        paletteWindow = nil
        paletteList = nil
        paletteItems = []
        resumeAutoFollow()
    }

    /// Move the highlighted palette result up/down (Up/Down arrows from the search entry), clamped at the
    /// ends. The result list stays focused on the entry so typing continues to filter.
    func paletteMove(down: Bool) {
        guard let lb = paletteList else { return }
        let idx = gtk_list_box_get_selected_row(lb).map { Int(gtk_list_box_row_get_index($0)) } ?? -1
        let newIdx = idx + (down ? 1 : -1)
        if let row = gtk_list_box_get_row_at_index(lb, Int32(newIdx)) {
            gtk_list_box_select_row(lb, row)
            scrollListBoxRowIntoView(lb, toIndex: newIdx)
        }
    }

    /// The palette scrolled-window's vertical adjustment (the list box is wrapped in a viewport).
    private func paletteVadjustment() -> UnsafeMutablePointer<GtkAdjustment>? {
        guard let lb = paletteList,
              let scroller = gtk_widget_get_ancestor(W(lb), gtk_scrolled_window_get_type()) else { return nil }
        return gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
    }

    /// Keep the keyboard-selected row visible: the search entry keeps focus, so GtkListBox won't auto-scroll
    /// to a programmatic selection — clamp the scrolled window to the (uniform-height) row's extent ourselves.
    /// Clamp a list box's scrolled window so the row at `index` is fully visible. Shared by the command
    /// palette + theme picker (both keep focus in their search entry, so GtkListBox won't auto-scroll a
    /// programmatic selection). Uses the row's ACTUAL position — uniform index×height underestimated the
    /// offset, so scrolling DOWN lagged a row behind the selection. clamp_page brings [y, y+h] into view.
    func scrollListBoxRowIntoView(_ lb: OpaquePointer, toIndex index: Int) {
        guard let scroller = gtk_widget_get_ancestor(W(lb), gtk_scrolled_window_get_type()),
              let vadj = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller)),
              let row = gtk_list_box_get_row_at_index(lb, Int32(index)) else { return }
        var origin = graphene_point_t()
        var translated = graphene_point_t()
        guard gtk_widget_compute_point(W(OpaquePointer(row)), W(lb), &origin, &translated) != 0 else { return }
        let ry = Double(translated.y)
        gtk_adjustment_clamp_page(vadj, ry, ry + max(1, Double(gtk_widget_get_height(W(OpaquePointer(row))))))
    }
}

private let onPaletteSearch: @convention(c) (OpaquePointer?, gpointer?) -> Void = { entry, _ in
    MainActor.assumeIsolated {
        let text = gtk_editable_get_text(entry).map { String(cString: $0) } ?? ""
        gController?.filterPalette(text)
    }
}
private let onPaletteActivate: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    MainActor.assumeIsolated { gController?.runPaletteSelected() }
}
private let onPaletteRow: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, row, _ in
    MainActor.assumeIsolated { gController?.runPaletteRow(row) }
}
private let onPaletteKey: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { _, keyval, _, _, _ in
    switch keyval {
    case 0xFF1B: MainActor.assumeIsolated { gController?.closePalette() }; return 1        // Esc
    case 0xFF52: MainActor.assumeIsolated { gController?.paletteMove(down: false) }; return 1  // Up
    case 0xFF54: MainActor.assumeIsolated { gController?.paletteMove(down: true) }; return 1   // Down
    default: return 0
    }
}
private let onPaletteDestroyed: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeRetainedValue().paletteWasDestroyed()
    }
}

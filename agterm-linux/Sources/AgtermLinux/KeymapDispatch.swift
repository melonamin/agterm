// Keymap-driven key dispatch: turns the shared, host-free keymap (user-rebound built-ins + custom
// shell commands) into AppController actions. The GTK key handler (GhosttySurface.keyPressed) stays
// thin — it calls handleKey(...) and this file owns all the logic, mirroring the macOS menu-equivalent +
// CustomCommandRunner split over the SAME agtermCore Keymap/KeybindMatcher.
//
// Resolution: a built-in's chord is `keymap.builtinOverrides[action] ?? action.linuxDefaultChord` (the
// macOS BuiltinAction.defaultChord is Cmd-based and unsuitable on Linux). Custom commands feed a
// KeybindMatcher (simple chords + leader sequences). The arrow/page nav, the font keys, and the reserved
// monitor chords (Ctrl+Tab, Ctrl+1/2) are not Chord-expressible / not rebindable and stay in a fixed
// fallback.
import CGtk
import Foundation
import agtermCore

/// The custom-command leader deadline fired on the main loop — abandon the half-typed sequence.
/// Returns G_SOURCE_REMOVE (one-shot).
private let onLeaderTimeout: @convention(c) (gpointer?) -> gboolean = { _ in
    MainActor.assumeIsolated { gController?.leaderDeadlineFired() }
    return 0
}

@MainActor
extension AppController {
    /// (Re)load keymap.conf and rebuild the dispatch caches: the resolved built-in chord→action map, the
    /// custom-command leader matcher, and the id→command lookup. Returns the parse-diagnostic count.
    /// Called at startup and from the `keymap.reload` control command.
    @discardableResult
    func reloadKeymapDiagnostics() -> Int {
        let (km, diagnostics) = KeymapStore(configDirectory: configDirectory()).load()
        keymap = km

        // Reverse map: defaults for un-overridden actions first, then overrides (so an override REPLACES
        // its action's default chord; a genuine chord collision resolves override-wins). Reserved monitor
        // chords are never inserted — they're handled by the fixed fallback.
        var reverse: [Chord: BuiltinAction] = [:]
        for action in BuiltinAction.allCases where km.builtinOverrides[action] == nil {
            if let chord = action.linuxDefaultChord, !isReservedMonitorChord(chord) { reverse[chord] = action }
        }
        for (action, chord) in km.builtinOverrides where !isReservedMonitorChord(chord) {
            reverse[chord] = action
        }
        resolvedBuiltinChords = reverse

        // Custom commands: the shared engine indexes by id + builds the leader matcher (parseKeymap already
        // cleared shortcuts that collide with built-ins / reserved chords / each other).
        customCommandEngine = CustomCommandEngine(commands: km.commands)
        // Surface parse errors instead of silently dropping the bad lines (kitty-style: a malformed line
        // is skipped, the rest of the file still loads) — a transient banner naming the count.
        if !diagnostics.isEmpty {
            let n = diagnostics.count
            showToast("keymap.conf: \(n) error\(n == 1 ? "" : "s") — bad line\(n == 1 ? "" : "s") ignored")
        }
        return diagnostics.count
    }

    /// The single entry point for a terminal key press (called by GhosttySurface.keyPressed). Returns
    /// true when the key was consumed as an app shortcut / custom command; false to let libghostty encode
    /// it for the terminal. Dispatch order: Esc leader-abort → reserved monitor chords → custom-command
    /// matcher → built-in (override/default) → fixed fallback (arrows, page-nav, font).
    func handleKey(keyval: UInt32, keycode: UInt32, state: UInt32, sessionID: UUID,
                   origin: GhosttySurface? = nil) -> Bool {
        // Reset the leader deadline to the FINAL armed state on every exit: a fresh leader (re)starts the
        // 1.5s timer, a fired/aborted leader cancels it (macOS-parity leader timeout — see syncLeaderDeadline).
        defer { syncLeaderDeadline() }
        // Escape: abort a half-typed leader (consumed); otherwise pass through to the terminal.
        if keyval == 0xFF1B {
            if customCommandEngine.isArmed { customCommandEngine.reset(); return true }
            return false
        }

        guard let chord = chord(fromKeyval: keyval, state: state) else {
            // A non-Chord key (arrow/page/F-key) can't continue a leader sequence; abandon a half-typed
            // one so a stale prefix can't complete across it (there's no Linux leader timeout yet).
            if customCommandEngine.isArmed { customCommandEngine.reset() }
            return fallbackShortcut(keyval: keyval, state: state, sessionID: sessionID, origin: origin)
        }

        // Reserved monitor chords (Ctrl+Tab, Ctrl+1/2) are never rebindable — they also can't be part of a
        // custom keybind, so abandon any armed leader and go straight to the fallback.
        if isReservedMonitorChord(chord) {
            if customCommandEngine.isArmed { customCommandEngine.reset() }
            return fallbackShortcut(keyval: keyval, state: state, sessionID: sessionID, origin: origin)
        }

        // Custom-command leader matcher (disjoint from built-ins by parseKeymap validation).
        switch customCommandEngine.advance(chord) {
        case .fired(let cmd):
            runCustomCommand(cmd)
            return true
        case .armed:
            return true   // leader in progress: consume and wait for the next chord
        case .unmatched:
            break
        }

        // Built-in (user override or Linux default).
        if let action = resolvedBuiltinChords[chord] {
            dispatchBuiltin(action, sessionID: sessionID)
            return true
        }

        // Expressible but unbound (e.g. the font keys): the fixed fallback.
        return fallbackShortcut(keyval: keyval, state: state, sessionID: sessionID)
    }

    /// Abandon a half-typed leader sequence (called on terminal focus loss — mirrors the macOS
    /// first-responder gate).
    func resetLeader() { customCommandEngine.reset() }

    /// Sync the leader deadline to the matcher's armed state (called via `defer` on every key): cancel any
    /// pending timer, then (re)arm a 1.5s g_timeout if a leader sequence is partially entered, so a
    /// half-typed leader self-aborts after the deadline — the Linux analogue of the macOS 1.5s timeout.
    private func syncLeaderDeadline() {
        cancelLeaderDeadline()
        if customCommandEngine.isArmed {
            leaderTimeout = g_timeout_add(1500, onLeaderTimeout, nil)
        }
    }
    private func cancelLeaderDeadline() {
        if leaderTimeout != 0 { g_source_remove(leaderTimeout); leaderTimeout = 0 }
    }
    /// The leader timer fired (no completing chord in time): abandon the half-typed sequence. The source
    /// auto-removes (the callback returns G_SOURCE_REMOVE), so just clear the id + reset the matcher.
    func leaderDeadlineFired() {
        leaderTimeout = 0
        resetLeader()
    }

    /// Map a rebindable `BuiltinAction` to its AppController method. EXHAUSTIVE: adding a BuiltinAction
    /// case fails to compile until it's wired, the Linux analogue of the macOS menu keep-in-sync. Actions
    /// with no Linux surface are no-ops (and never reach here unless the user explicitly `map`s them).
    private func dispatchBuiltin(_ action: BuiltinAction, sessionID: UUID) {
        switch action {
        case .newWindow: openNewWindow()
        case .renameWindow: break          // no inline window rename on Linux yet
        case .deleteWindow: break          // window close is via the titlebar / window.close control
        case .newWorkspace: newWorkspace()
        case .renameWorkspace: if let ws = store.currentWorkspaceID { beginRename(id: ws, isWorkspace: true) }
        case .deleteWorkspace: if store.canRemoveWorkspace, let ws = store.currentWorkspaceID { store.removeWorkspace(ws); reconcile() }
        case .newSession: newSession()
        case .openDirectory: openDirectory()
        case .renameSession: startRenameActive()
        case .closeSession: requestCloseSession(sessionID)
        case .clearStatus: clearActiveStatus()
        case .increaseFontSize: focusedSurface()?.performBindingAction(FontBindingAction.increase)
        case .decreaseFontSize: focusedSurface()?.performBindingAction(FontBindingAction.decrease)
        case .resetFontSize: focusedSurface()?.performBindingAction(FontBindingAction.reset)
        case .toggleSplit: toggleSplit()
        case .toggleScratch: toggleScratch()
        case .toggleSearch: toggleSearch()
        case .toggleSidebar: toggleSidebar()
        case .selectTheme: showThemePicker()
        case .toggleFlaggedView: toggleFlaggedView()
        case .toggleFlag: toggleFlagActive()
        case .focusWorkspace: focusActiveWorkspace()   // toggle focus on the active session's workspace
        case .focusLeftPane: focusPane(left: true)
        case .focusRightPane: focusPane(left: false)
        case .previousSession: navigate(.previous)
        case .nextSession: navigate(.next)
        case .previousAttentionSession: navigate(.previousAttention)
        case .nextAttentionSession: navigate(.nextAttention)
        case .firstSession: navigate(.first)
        case .lastSession: navigate(.last)
        case .quickTerminal: toggleQuick()
        case .sessionPalette: showSessionPalette()
        case .commandPalette: showPalette()
        case .customCommandPalette: showPalette()   // the palette already lists custom commands
        case .showAttention: showAttentionPalette()
        }
    }

    /// The non-rebindable shortcuts: arrow/page navigation + reorder, the reserved monitor chords
    /// (Ctrl+Tab MRU switch, Ctrl+1/2 pane focus), and the font keys (Ctrl+=/+/-/0 — kept here so both
    /// `=` and `+` increase, while a user `map` can still rebind the font actions through the matcher).
    private func fallbackShortcut(keyval: UInt32, state: UInt32, sessionID: UUID,
                                  origin: GhosttySurface? = nil) -> Bool {
        let ctrl = (state & (1 << 2)) != 0
        let shift = (state & (1 << 0)) != 0
        let altOrSuper = (state & ((1 << 3) | (1 << 26))) != 0   // Alt/Super also held → not a reserved/font chord
        if ctrl, shift {
            switch keyval {
            case 0xFF52: reorderActiveSession(.up); return true        // Ctrl+Shift+Up
            case 0xFF54: reorderActiveSession(.down); return true      // Ctrl+Shift+Down
            case 0xFF55: reorderActiveWorkspace(.up); return true      // Ctrl+Shift+PageUp
            case 0xFF56: reorderActiveWorkspace(.down); return true    // Ctrl+Shift+PageDown
            case 0xFF51: focusPane(left: true); return true           // Ctrl+Shift+Left
            case 0xFF53: focusPane(left: false); return true          // Ctrl+Shift+Right
            case 0x2B: (origin ?? focusedSurface())?.performBindingAction(FontBindingAction.increase); return true  // Ctrl++
            default: return false
            }
        } else if ctrl, !altOrSuper {
            // Sole-Control (no Alt/Super): the reserved pane chords + the font keys. A `where` on a
            // multi-pattern case binds only the last pattern, so the Alt/Super exclusion is on the branch.
            switch keyval {
            case 0xFF56: navigate(.next); return true                 // Ctrl+Page_Down
            case 0xFF55: navigate(.previous); return true             // Ctrl+Page_Up
            case 0xFF09: quickSwitchSession(); return true            // Ctrl+Tab (reserved MRU switch)
            case 0x31, 0x32:                                          // Ctrl+1 / Ctrl+2 (reserved; split only)
                guard store.session(withID: sessionID)?.hasSplit == true else { return false }
                focusPane(left: keyval == 0x31); return true
            case 0x3D, 0x2B: (origin ?? focusedSurface())?.performBindingAction(FontBindingAction.increase); return true  // Ctrl+= / +
            case 0x2D, 0x5F: (origin ?? focusedSurface())?.performBindingAction(FontBindingAction.decrease); return true  // Ctrl+-
            case 0x30: (origin ?? focusedSurface())?.performBindingAction(FontBindingAction.reset); return true            // Ctrl+0
            default: return false
            }
        }
        return false
    }
}

# agterm Linux ⇄ macOS UI parity

Goal: the Linux GTK UI reaches feature parity with the macOS SwiftUI UI, with **both
UIs as thin layers over the shared controller** (`agtermCore.AppStore` — every state
mutation lives there; `AppActions` on macOS and `AppController` on Linux are thin
adapters that call it and reconcile their views). Surface-level terminal ops go through
`GhosttySurface.performBindingAction` / a few direct libghostty calls, mirroring
`GhosttySurfaceView`.

Legend: ✅ done · �doing · ⬜ todo

## Core model & navigation
- ✅ Workspaces + sessions, two-level sidebar
- ✅ Multiple sessions in a deck (GtkStack), switch keeps each shell alive
- ✅ New session / new workspace / close session
- ✅ Session nav next/prev (Ctrl+PageUp/Down) + first/last/attention (controller)
- ✅ Session reorder within workspace (Ctrl+Shift+Up/Down) — `AppStore.reorderSession`
- ⬜ Workspace reorder — `AppStore.reorderWorkspace`
- ⬜ Move session to another workspace — `AppStore.moveSession`
- ✅ Ctrl-Tab MRU switch — `RecencyStack` top-2 toggle (Alt-Tab-between-two); hold-to-cycle overlay deferred

## Editing & chrome
- ✅ Inline rename session (Ctrl+Shift+R, GtkEditableLabel) — `AppStore.renameSession`; workspace rename via control; row context menu ⬜
- ✅ Sidebar show/hide (Ctrl+Shift+B) — AdwOverlaySplitView + `AppStore.sidebarVisible`
- ⬜ Workspace delete with keep-one guard — `AppStore.removeWorkspace`
- ✅ Window title tracks active session displayName (OSC title + live cwd)

## Terminal surface
- ✅ `performBindingAction` seam on `GhosttySurface`
- ✅ Font size inc/dec/reset (Ctrl +/-/0)
- ✅ Splits — one session, two shells (Ctrl+Shift+D), `AppStore.toggleSplit` + GtkPaned (click-to-focus a pane; promote-on-primary-exit deferred)
- ✅ Scratch terminal (Ctrl+Shift+J + session.scratch) — `AppStore.toggleScratch`, outer GtkStack main↔scratch
- ⬜ Overlay terminal — `AppStore.openOverlay`
- ✅ In-terminal search bar (Ctrl+Shift+F) — GtkSearchEntry + match count + prev/next/close; `start_search`/`search:`/`navigate_search`/`end_search`; also drivable via `session.search`
- ⬜ Copy/paste selection helpers (`readSelection`, `inject`) — mostly via ghostty binds

## Working set & focus
- ✅ Flag session (Ctrl+Shift+G) + flagged-only view (Ctrl+Shift+E) — `AppStore.setFlag`/`sidebarMode`; ★ glyph on rows (Ctrl+Shift+F is now search)
- ✅ Focus filter respected in sidebar (renders `visibleWorkspaces`); setter UI ⬜
- ✅ Agent-status glyph on rows — driven by `session.status` over the control socket
- ⬜ Unseen badge — `Session.unseenCount`

## Palettes & settings
- ✅ Command palette (Ctrl+Shift+P) — modal GtkSearchEntry + GtkListBox, fuzzy-filtered via shared `fuzzyScore`; runs thin controller actions
- ⬜ Session switcher palette
- ✅ Theme picker (live preview) — modal GtkSearchEntry + GtkListBox over 463 bundled ghostty themes; arrow/type previews live via `ghostty_surface_update_config`, Enter commits+persists, Esc reverts; opened from the command palette ("Change Theme…"); also `theme.set`/`theme.list` control + persists across relaunch
- ⬜ Settings window — `SettingsModel`
- ⬜ Keymap (kitty .conf) load + apply — `Keymap`/`KeybindMatcher`

## System integration
- ✅ Persistence / restore on relaunch — `AppStore.snapshot`/`restore` (sessions, splits, names, cwd, selection survive; XDG `~/.local/share/agterm/workspaces.json`)
- �doing Control socket — `ControlServer` (unix socket, GLib-main hop) + shared `agtermctl`. Done: tree, session new/close/select/rename/type/copy/status/flag/split/go/move/focus, workspace new/rename/delete/move/focus, sidebar/sidebar.mode, font.*, notify, restore.clear, scratch, search, theme.set/theme.list, config.reload, window.new/list/select/close/rename/delete. Remaining: overlay/window.resize/window.move/keymap/quick.
- ⬜ Copy/paste selection (`session.copy` ✅; clipboard binds ✅ via ghostty)
- ✅ Desktop notifications (OSC 9/777 + `notify` command) — via notify-send (libnotify CLI)
- ✅ Multi-window — shared `WindowLibrary` (one AppStore per window, windows.json + windows/<id>.json, migrates legacy workspaces.json); per-window AppController, frontmost routing, reopen-on-launch; "New Window" palette action + window.new/list/select/close/rename/delete control. (window.resize/move ⬜)
- ⬜ Quick terminal
- ⬜ Ship ghostty terminfo + shell-integration

## Architecture rule
Anything UI-agnostic belongs in `agtermCore` (shared controller), not in `AppController`
or the macOS app target. When adding a feature, the GTK side should be: translate input
→ call `AppStore` → `reconcile()`. If logic doesn't fit that shape, push it into the core.

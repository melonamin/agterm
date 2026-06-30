# Linux port — handoff for the macOS-half + tooling tail

The GTK4/libadwaita Linux port (`agterm-linux/`) reached deep parity over the shared, host-free
`agtermCore` package: **93/97** gaps in `LINUX_GAP_ANALYSIS.md` closed, 33/44 control commands routed
through the shared `ControlDispatcher`, and ~20 logic hoists. Everything Linux-verifiable is done and
runtime-checked.

What remains needs one of two things this dev environment **cannot** provide:

- **(A) the macOS target compiled.** Several shared components were hoisted into `agtermCore` and adopted
  by the **Linux** side, but the **macOS** side still carries its own inline copy. Switching macOS onto
  the shared component is the keep-in-sync completion (clause 2). It can't be done here — `agterm/` builds
  only with Xcode 26 + libghostty's `GhosttyKit.xcframework`, neither of which exists on this Linux box.
- **(B) tooling absent from this box:** `flatpak-builder` (no flatpak runtime here) and a GTK-capable CI
  runner with a headless display + session/a11y D-Bus.

This doc enumerates both so they can be finished where the tooling/Mac exist.

---

## Part A — macOS-half adoptions

Each row: the **shared** component (in `agtermCore`, already done + tested), the **macOS file** to change,
the **change**, the **test**, and the **risk**. **Verified against the real macOS call sites (not just a
symbol grep): A1, A2, A4–A8 are seven genuine pending adoptions, each anchored to an exact line below.
A3 (`shiftedHex`) and A9 (`TranslucencyMode`) turned out Linux-only — zero macOS references — so they
need NO macOS change; they're kept below only to record that they were checked.**

After every change: `swift test` in `agtermCore` must stay green, then build the macOS app and run the
`agtermUITests` control round-trip/e2e suite.

### A1 — `ControlDispatcher` / `ControlActions`  (the big one)
- **Shared:** `agtermCore/Sources/agtermCore/ControlDispatcher.swift` — a host-free command switch + mode
  parse + error strings + name-addressing behind a `ControlActions` protocol the platform implements.
  **UPDATED this session:** the dispatcher now also owns `session.overlay.*` (3) and `window.*` (7), so the
  `ControlActions` seam grew a window slice — `var library: WindowLibrary` + `presentWindow(_:)` /
  `closeWindow(_:) -> Bool` / `resizeWindow(_:width:height:)` — plus the dispatcher's `notFound` learned a
  `"window"` case. The macOS conformer must implement that slice too. The ONLY commands still
  platform-inline (by design) are `session.search`, `window.move`, `restore.clear`.
- **macOS:** `agterm/Control/ControlServer.swift` — `dispatch(_ request:) async -> ControlResponse` at
  **line 316** is a ~250-line hand-rolled switch (`.sessionSelect`, `.sessionGo`, `.sessionNew`, …).
- **Change:** give the macOS a `ControlActions` conformer (mapping the protocol methods onto
  `AppActions`/`AppStore`, exactly as `agterm-linux`'s `AppController` does), and in `dispatch` route the
  shared commands through `ControlDispatcher.dispatch(_:actions:)`. Map the window-seam methods onto the
  macOS `WindowRegistry`/`NSWindow` (Linux maps them to `gWindows` + `gtk_window_*` in
  `ControlActions+AppController.swift`). Keep only `window.move` + `reveal` + quit-confirm inline — `window.*`
  except `move` is now in the dispatcher. The Linux conformer
  (`agterm-linux/Sources/AgtermLinux/{ControlActions+AppController,AppController}.swift`) is the reference,
  and `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift` (the `MockControlActions` + the overlay
  + window dispatch tests) shows the exact expected behavior to mirror in a macOS unit test.
- **Test:** the existing `agtermUITests` control e2e must pass unchanged (same wire behavior). Add a
  macOS unit test asserting the dispatcher path returns identical responses to the old switch for a few
  commands.
- **Risk:** medium — it's the load-bearing control path. Do it command-group by command-group, not in one
  sweep; the wire protocol (`ControlProtocol`) is unchanged so each command is independently verifiable.

### A2 — `ControlResolve.ambiguousMessage`
- **Shared:** `agtermCore/.../ControlResolve.swift` — `ambiguousMessage(noun:target:matches:)` →
  `"ambiguous <noun> prefix '<t>' → <8-char ids>"`.
- **macOS:** `agterm/Control/ControlServer.swift` **line 1213** — already imports `ControlResolve` (1 ref)
  but builds the string inline: `error: "ambiguous \(noun) prefix '\(target)' → \(listed)"`.
- **Change:** replace the inline string with `ControlResolve.ambiguousMessage(noun:target:matches:)`.
- **Test:** existing resolve tests; add one asserting the ambiguous message text.
- **Risk:** trivial (string identity).

### A3 — `ThemeColorResolver.shiftedHex` — ⚠️ NOT a macOS adoption (Linux-only)
- **Verified:** grep found **zero** `ThemeColorResolver` / lighten / darken / shifted references in
  `agterm/`. The macOS derives chrome colors via `NSColor` blending, not a hex shift, so `shiftedHex`
  (and the whole `ThemeColorResolver`) is Linux-only — it backs the Linux sidebar tint. **No macOS change
  needed.** Listed here only to record that it was checked (the `ThemeColorResolverTests` stay green).

### A4 — `OverlayCapture`
- **Shared:** `agtermCore/.../OverlayCapture.swift` — the env keys (`AGTERM_OVL_CMD`/`AGTERM_OVL_CODE`)
  + the fixed `sh -c` wrapper (`shellLine`) + `parseExitCode`.
- **macOS:** `agterm/agtermApp.swift` — **line 576** `private static let overlayExitWrapper =
  "sh -c '( eval \"$AGTERM_OVL_CMD\" ); echo $? > \"$AGTERM_OVL_CODE\"'"`, and **lines 590–591** set
  `overlayEnv["AGTERM_OVL_CMD"]` / `["AGTERM_OVL_CODE"]` (inside `makeOverlaySurface(for:store:env:)`).
- **Change:** source the wrapper body from the shared constant —
  `overlayExitWrapper = "sh -c '\(OverlayCapture.shellLine)'"` — and the two env-key literals from
  `OverlayCapture.cmdEnvKey` / `.codeEnvKey`; parse the exit file with `OverlayCapture.parseExitCode`.
- **Test:** `session.overlay.open … --block` round-trips the exit code (already an e2e shape on Linux).
- **Risk:** low (identical string, now sourced once). NOTE the Linux teardown fix: defer the overlay
  `onExit` past ghostty's `SHOW_CHILD_EXITED` callback — the macOS already does this via
  `close_surface_cb` (never frees synchronously), so no macOS change needed there.

### A5 — `PaletteCommand` + `PaletteContext.isVisible`
- **Shared:** `agtermCore/.../PaletteCatalog.swift` — the 28-command catalog (id + title) + the visibility
  predicates (`isVisible(in: PaletteContext)`).
- **macOS:** `agterm/Views/Palette.swift` (and `AppActions.swift` for the action wiring) — builds its own
  command list + titles. (The macOS's existing `isVisible` refs are menu-item visibility, a different
  thing.)
- **Change:** iterate `PaletteCommand.allCases`, map each id to its macOS action via an **exhaustive**
  switch (the compiler then guarantees no drift), and `.filter { $0.isVisible(in: ctx) }` where `ctx` is
  built from the store (`flaggedSessions` / `workspaces.count` / `sidebarMode == .flagged`). Mirror
  `agterm-linux/Sources/AgtermLinux/Palette.swift`.
- **Test:** `PaletteCatalogTests` (shared) already cover titles + visibility; add a macOS test that the
  palette omits Clear Flagged / Expand-Collapse in the no-op states.
- **Risk:** low–medium (the macOS palette is a SwiftUI list; keep its existing fuzzy/ordering behavior).

### A6 — `CustomCommandEngine`
- **Shared:** `agtermCore/.../CustomCommandEngine.swift` — wraps a `KeybindMatcher` + id index;
  `advance(_:) -> .fired/.armed/.unmatched`, `isArmed`, `reset()`.
- **macOS:** `agterm/Commands/CustomCommandRunner.swift` — holds its own matcher + commands-by-id.
- **Change:** replace the matcher/index pair with a `CustomCommandEngine`; keep the macOS spawn path
  (`/bin/sh -c` with `$AGT_*`) — only the *matching* is hoisted.
- **Test:** `CustomCommandEngineTests` (shared) + the existing macOS custom-command UI test.
- **Risk:** low (pure matching logic; the spawn side is untouched).

### A7 — `KeymapStore`
- **Shared:** `agtermCore/.../` `KeymapStore` (load = parse + recover, tested).
- **macOS:** `agterm/Ghostty/GhosttyApp.swift` / `AppActions.swift` — the keymap.conf load + reload.
- **Change:** load through `KeymapStore(configDirectory:defaults:).load()`; surface the diagnostic count
  the same way (the macOS already has a banner channel).
- **Test:** existing keymap UI tests + the shared `KeymapStore`/`ConfigPaths` tests.
- **Risk:** low.

### A8 — `ConfigPaths.starterKeymapConf`
- **Shared:** `agtermCore/.../ConfigPaths.swift` — `starterKeymapConf()` (generated from
  `BuiltinAction.allCases`) + `starterRestoreDenylist()` (macOS already adopted the denylist one).
- **macOS:** `agterm/SettingsModel.swift` — **`ensureStarterKeymap()` (line 322)** already seeds
  `keymap.conf`, but from its OWN **`starterKeymapText()` (line 376)** rather than the shared generator
  (so the two starter texts can drift).
- **Change:** replace the body of `starterKeymapText()` with `ConfigPaths.starterKeymapConf()` (or delete
  it and call the shared one at the seeding site), so both platforms emit the same starter.
- **Test:** assert the seeded file parses with zero diagnostics (it's generated from `BuiltinAction.allCases`).
- **Risk:** trivial.

### A9 — `AppSettings.TranslucencyMode.rendererBlended` — ⚠️ NOT a macOS adoption (Linux-only)
- **Verified:** grep found **zero** `TranslucencyMode` references in `agterm/`. The macOS applies
  translucency from an opacity value (`GhosttyApp.setWindowTranslucency` + a `SettingsModel` slider), not
  this enum — so the new `.rendererBlended` case is Linux-only and is **NOT a compile gate** (there is no
  macOS `switch` over `TranslucencyMode` to update). **No macOS change needed.** (If a future macOS change
  ever switches over the enum, it would then need a `.rendererBlended` arm — but nothing does today.)

---

## Part B — flatpak build  (gap L327)

- **Manifest:** `packaging/linux/flatpak/com.umputun.agterm.linux.yml` exists (unbuilt here — no
  `flatpak-builder`).
- **Runtime/SDK:** `org.gnome.Platform`/`org.gnome.Sdk` (47+) for GTK4 + libadwaita. Swift is the hard
  part — the GNOME SDK has no Swift toolchain, so either bundle the Swift 6.3.2 runtime libs into the
  app (`org.freedesktop.Sdk.Extension.swift` if available, else vendor `libswift*.so` like
  `scripts/dist-linux.sh` does) or build with a Swift SDK extension.
- **libghostty:** vendor the prebuilt `agterm-linux/vendor/ghostty/lib/libghostty.so` + the
  `share/ghostty` resources (incl. the themes — see `scripts/setup-linux.sh`) into the flatpak; set the
  rpath/`GHOSTTY_RESOURCES_DIR` to the in-sandbox path.
- **Build:** `flatpak-builder --force-clean build-dir packaging/linux/flatpak/com.umputun.agterm.linux.yml`
  then `flatpak-builder --run … agterm-linux` to smoke-test.
- **Verify:** window + GL terminal render, the control socket under `XDG_RUNTIME_DIR`, theme picker
  populated. Sandbox holes likely needed: `--socket=wayland --socket=fallback-x11 --device=dri
  --share=ipc` and a socket path the host `agtermctl` can reach (or document control-from-inside only).

## Part C — GTK-in-CI  (gaps L246 + tail of L327)

Add a Linux job to `.github/workflows/ci.yml` (the file exists; today it builds macOS + `agtermCore`):

1. **Runner:** `ubuntu-24.04`.
2. **Deps:** `libgtk-4-dev libadwaita-1-dev` + the Swift 6.3.2 toolchain (the repo pins the
   ubuntu24.04 Swift; reuse the `mise`/compat-symlink setup from `MEMORY.md`’s toolchain note).
3. **libghostty:** the slow part. Either (a) `scripts/setup-linux.sh` once and **cache** the
   `agterm-linux/vendor/ghostty/{lib,include,share}` outputs (keyed on `GHOSTTY_REV`), or (b) publish the
   vendored `.so` + resources as a CI artifact and download it. Don't rebuild ghostty every run.
4. **Headless display + buses** (needed for the launch-based tests):
   - `xvfb-run -a` (or a headless Wayland like `cage`/`weston --headless`) for a display.
   - `dbus-run-session --` to wrap the test step so `GApplication` single-instance + the notification
     `app.reveal` action have a session bus.
   - For the AT-SPI smoke (`agterm-linux/tests/atspi_smoke.py`): start the a11y bus
     (`/usr/libexec/at-spi-bus-launcher --launch-immediately`) and export
     `GTK_A11Y=atspi` / `AT_SPI_BUS`.
5. **Test steps:**
   - `cd agtermCore && swift test` (host-free; runs anywhere — could even stay on the macOS job).
   - `cd agterm-linux && swift build` (needs the vendored libghostty from step 3).
   - control e2e: launch `AgtermLinux` with an isolated `AGTERM_STATE_DIR` + `AGTERM_CONTROL_SOCKET`,
     then drive `agtermctl` (tree / session.new / session.type / session.overlay … --block) and assert.
     This is exactly the loop the dev verification used this session — script it.
   - `python3 agterm-linux/tests/atspi_smoke.py` (sidebar a11y tree assertion).
6. **Isolation:** every launch uses a temp `AGTERM_STATE_DIR` + socket + a distinct `AGTERM_APP_ID`
   (the Linux analogue of the macOS `.debug` bundle id) so parallel jobs don't collide.

---

## Part D — the two deferred Linux refinements  (gaps L342, L300/L304)

These are Linux-only and *can* be done in this environment, but were deferred (maintainer's call) over
regression risk to currently-working code. Risk profiles below are **verified against the actual code**,
not guessed.

### D1 — overlay floating sized panel (L342) — **additive, LOW risk** ✅
- **What:** `session.overlay.open --size-percent N` currently renders the overlay FULL-screen on Linux
  (the percent is ignored). The macOS shows a floating panel at N% with the session visible behind it.
- **Verified additive:** the floating path does NOT touch the working full-overlay path. The full overlay
  mounts the surface in the per-session deck `GtkStack` (the `"overlay"` child) — leave that as-is. The
  floating panel mounts into the existing window-level `deckOverlay` (`GtkOverlay`,
  `AppController.swift:202`) via the SAME `gtk_overlay_add_overlay` / `remove_overlay` calls the **quick
  panel** already uses (`setQuick`, line 412–431 — a working proof). It's a new branch, not a rewrite.
- **Approach:** in `syncOverlay` (~line 1049) branch on `s.overlaySizePercent`. If set: build a framed
  card (`gtk_frame_new` + the `"card"`/`"agterm-quick"`-style CSS, exactly like `quickFrame`) around
  `ov.glArea`, size it to `deckOverlay` width/height × percent (`GTK_ALIGN_CENTER` + `set_size_request`,
  vs the quick panel's fixed margins), `gtk_overlay_add_overlay`, and do NOT switch the deck stack (the
  session stays visible). If nil: the current full path, unchanged. Close: floating frame →
  `gtk_overlay_remove_overlay`; else the current full close.
- **The one extra hook:** the floating frame is window-level, so it isn't auto-hidden on session switch
  (the full overlay is, because the deck shows one session). Tie its visibility to the active session in
  `showActive()` (`gtk_widget_set_visible`) — additive to `showActive`, still no change to the full path.
  Or accept the minor transient glitch for a first cut (the overlay is short-lived + opening it selects
  its session).
- **Verify:** `--size-percent 50` shows a centered card with the session around it; the no-percent overlay
  still covers the session; `--block` exit capture still works; screenshot both; 0 crashes.
- **Risk:** LOW. This is the refinement that **no longer carries the regression risk it was deferred for**
  — confirmed once the `deckOverlay` + quick-panel pattern made the additive path concrete.

### D2 — sidebar per-row reconcile diff (L300/L304) — **NOT additive, MEDIUM-HIGH risk** ⚠️
- **What:** `reconcile()` (line 978) calls `rebuildSidebar()` (line 1319) — a full teardown+rebuild of the
  sidebar on every model change. The refinement: diff old-vs-new + apply per-row ops (the macOS
  `SidebarReconcile` shape-vs-content diff), from one `withObservationTracking` entry point.
- **Why risky:** the sidebar is the most stateful Linux surface — drag-reorder, focus filter, context
  menu, inline rename, disclosure triangle, selection. The full rebuild is correct (just heavier); a diff
  is an OPTIMIZATION (kill flicker / preserve scroll), not a feature, and a mis-diff silently corrupts the
  tree.
- **Approach (if pursued):** extract a host-free `agtermCore.SidebarReconcile` that returns row ops
  (insert/delete/move/update at index) from old vs new snapshots; **unit-test it exhaustively in
  agtermCore first**; then apply the ops to the `GtkListBox` incrementally, keeping `rebuildSidebar()` as
  a feature-flagged fallback. Do NOT delete the full rebuild until the diff is proven across every
  interaction.
- **Risk:** MEDIUM-HIGH — worth it for the UX, but only with the core diff unit-tested + the full rebuild
  retained as a fallback.

## Reference: the Linux conformers to mirror

| Shared (`agtermCore`) | Linux reference (`agterm-linux/Sources/AgtermLinux/`) |
|---|---|
| `ControlDispatcher` / `ControlActions` | `AppController.swift` (the `ControlActions` conformance + `ControlServer.swift` dispatch) |
| `OverlayCapture` | `AppController.swift` `syncOverlay` |
| `PaletteCommand` / `PaletteContext` | `Palette.swift` |
| `CustomCommandEngine` | `KeymapDispatch.swift` |
| `KeymapStore` | `KeymapDispatch.swift` `reloadKeymap` |
| `ConfigPaths.starter*` | `WindowManager.swift` `ensureStarter*` |

The Linux side is the worked example for every adoption above — same `agtermCore` API, thin platform glue.

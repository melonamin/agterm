# agterm Linux port — findings and spike plan

A handoff document for a coding agent running on a Linux machine. Goal: validate whether a pure-Swift Linux/GTK port of `agterm` is feasible, by running a sequence of cheap spikes before committing to any UI work.

## Context

`agterm` is a macOS SwiftUI terminal that wraps `libghostty` (built from upstream `ghostty-org/ghostty` at a pinned SHA). It exposes a two-level workspace → session vertical sidebar, a 44-command control socket (`agtermctl`), keymaps in kitty `.conf` style, OSC 9/777 notifications, and a bundled agent skill. See `README.md` and `ARCHITECTURE.md` for the full picture; this doc only covers what matters for the Linux port.

The decision: **try a pure-Swift Linux build using SwiftGtk or Adwaita-Swift.** We rejected the alternatives (Rust + gtk-rs rewrite of the core; Swift core + Rust UI over an IPC socket; Zig to match upstream Ghostty's GTK frontend) because the maintainer wants one language and the cost of a sibling codebase is real. We are aware Swift-on-Linux GTK bindings are immature in 2026 and that is exactly what the spikes are meant to surface early.

## Architectural findings (already established, do not re-litigate)

The agterm codebase splits cleanly between a host-free Swift package (`agtermCore/`) and a macOS app target (`agterm/`). Roughly 56% of the code is reusable as-is:

**Reusable verbatim (~5,700 LOC):**
- `agtermCore/Sources/agtermCore/` — 34 files, 4,955 LOC. Foundation-only, `Sendable`-clean, CoreGraphics-free (uses `Double`-backed `Size`/`Point`/`Rect` shadow types per a hard CLAUDE.md rule). Owns: model (`Session`, `Workspace`, `WindowLibrary`, `WindowGeometry`), persistence (`PersistenceStore`, `Snapshot`, `AppSettings`, `SettingsStore`), the 44-command `ControlProtocol`, keymap parsing (`Keymap`, `Keybind`, `KeybindMatcher`, `BuiltinAction`), the `AppStore` hub (769 LOC, `@Observable @MainActor`, the single mutable state), and the `TerminalSurface` protocol (36 LOC, the only seam).
- `agtermCore/Sources/agtermctlKit/` + `agtermctl` main — pure Foundation + `swift-argument-parser`, builds with `swift build` (no Xcode).
- Install helpers (`CLIInstall`, `SkillInstall`, `AgentHooksInstall`) — pure path/JSON/shell-rc logic, unit-tested, no AppKit.

**AppKit/Metal-locked, needs rewrite (~4,500 LOC):**
- `agterm/Ghostty/` (1,683 LOC) — `GhosttySurfaceView` (1,000 LOC NSView + Metal layer + responder chain), `GhosttyCallbacks` (175 LOC, C → `DispatchQueue.main.async` hops), `GhosttyApp` (444 LOC, owns `ghostty_app_t`).
- SwiftUI/AppKit views (~2,667 LOC) — sidebar (`NSOutlineView` adapter), Settings tabs, Palette, SessionSwitcher, TerminalSearchBar, overlays.
- `ControlServer` socket I/O loop (the dispatch logic itself stays — the loop becomes GLib-driven).
- `NotificationManager` (NSUserNotificationCenter → libnotify / `org.freedesktop.Notifications`).

**The seam:** `agtermCore/Sources/agtermCore/TerminalSurface.swift` — a 36-LOC `@MainActor` protocol with `func teardown()` and a `SearchDirection` enum. On macOS, `GhosttySurfaceView: NSView` conforms. On Linux, a new `GhosttySurfaceWidget` wrapping `GtkGLArea` would conform.

## Reference: how Ghostty itself does cross-platform

Upstream `ghostty-org/ghostty`:
- Engine + apprts in `src/` (Zig).
- macOS frontend: `macos/Sources/` (~160 Swift files), links the `.lib` build of libghostty (same `GhosttyKit.xcframework` we use).
- GTK frontend: `src/apprt/gtk/` — **~52 `.zig` files + ~25 `.blp` Blueprint / `.ui` / `.css` files**. Raw `gobject-introspection` GTK4 + libadwaita bindings from Zig. No high-level wrapper.
- **No shared cross-platform UI layer.** The C ABI in `include/ghostty.h` (opaque handles + a `ghostty_action_s` tagged-union callback) is the only contract.

Key files worth reading line-by-line before writing Linux code:
- `include/ghostty.h` — the C ABI we link against.
- `src/apprt/embedded.zig` — the `.lib` build (what macOS and we consume).
- `src/apprt/gtk/Surface.zig` — canonical answer to "how do you wire `ghostty_surface_t` into a GTK widget" (GL area, key/mouse/scroll routing, sizing, IME via `GtkIMContext`).
- `src/apprt/gtk/App.zig` — main loop / `g_main_context` integration.
- `src/apprt/gtk/winproto/{wayland,x11}.zig` — protocol shims for transparency, blur, decorations, layer-shell.
- `src/apprt/gtk/class/{window,tab,split_tree}.zig` — windows/tabs/splits, conceptually close to our pane model.
- `src/apprt/gtk/ipc/new_window.zig` — single-instance launch IPC pattern (relevant precedent for our control socket interacting with `.desktop` launch).

These are reference, not lift — Zig doesn't translate to Swift. But every callback handled in `agterm/Ghostty/GhosttyCallbacks.swift` has a 1:1 Zig counterpart here.

## Target plan (assumes all spikes pass)

1. Keep `agtermCore` as the single source of truth for model, control protocol, keymap, settings. No fork.
2. New Swift app target `agterm-linux/` (or sibling repo — decide after spike 1) that:
   - Links `libghostty` Linux static/shared lib (built from same pinned ghostty SHA).
   - Conforms a new `GhosttySurfaceWidget` (GTK4 `GtkGLArea` wrapper) to `TerminalSurface`.
   - Reimplements `GhosttyCallbacks` against `g_main_context_invoke` instead of `DispatchQueue.main.async`.
   - Reimplements views in SwiftGtk or Adwaita-Swift: `AdwNavigationSplitView` for the workspace/session sidebar, `AdwPreferencesWindow` for Settings, `GtkPopover`/`GtkSearchEntry` for Palette and SessionSwitcher.
   - Reuses `agtermctl` verbatim — same binary, same wire protocol.
   - Replaces `NotificationManager` with libnotify or a DBus `org.freedesktop.Notifications` call.
   - Replaces Help-menu installers with a shell script + man page.
3. Maintain control-API parity (the HARD keep-in-sync rule from CLAUDE.md applies on Linux too). The agent skill at `agterm/Resources/agent-skill/` stays unchanged.

## Spike plan (risk-ordered, easiest first)

Run these in order. **Stop and report back after each one** — do not start spike N+1 if spike N reveals a blocker. Each spike has a clear pass/fail; we do not iterate on a failing spike without checking in.

### Spike 1 — libghostty builds for Linux (target: 1 hour)

**Goal:** Confirm `libghostty` (the `.lib`/embedded apprt) builds standalone on Linux and exposes the same `ghostty.h` C surface we use on macOS.

**Steps:**
1. Clone `ghostty-org/ghostty` at the SHA pinned in `scripts/setup.sh` (`GHOSTTY_REV`).
2. Install Zig 0.15.2 (matches what `scripts/setup.sh` uses on macOS).
3. Run `zig build -Dapp-runtime=none -Demit-shared-lib=true` (or whatever flag combo produces a Linux `libghostty.so`/`.a`; check `build.zig`).
4. Confirm the built artifact exports the symbols in `include/ghostty.h` (`nm -D libghostty.so | grep ghostty_`).
5. Write a 20-line C program that calls `ghostty_app_new`, then `ghostty_app_free`. Verify it links and runs without crashing.

**Pass:** library builds, symbols present, trivial C consumer works.
**Fail:** report what broke. Likely culprits: zig version mismatch, missing Linux-specific build flag, embedded apprt assuming macOS-only stuff.

### Spike 2 — `agtermCore` builds on Linux (target: 1 hour)

**Goal:** Confirm the host-free package is genuinely host-free.

**Steps:**
1. Install Swift 6.x on Linux (Swiftly or the swift.org Linux toolchain).
2. `cd agtermCore && swift build`.
3. `swift test`.

**Pass:** clean build, all tests green.
**Fail:** report which files don't build. Likely culprits: any `import Darwin`, `FileManager` API gaps, `String.Encoding` quirks, anything in `ConfigPaths` that hardcoded `~/Library/Application Support`. These are small fixes — make a note, don't fix in the spike.

### Spike 3 — `agtermctl` builds and runs on Linux (target: 30 min)

**Goal:** End-to-end socket-protocol portability.

**Steps:**
1. `cd agtermCore && swift build --product agtermctl`.
2. Run `./build/agtermctl --help` — confirm it lists subcommands.
3. Without a server running, run `./build/agtermctl session.list` — it should fail with a "no socket" error, not a crash.

**Pass:** binary builds, help text prints, error path is clean.
**Fail:** report. Same likely culprits as spike 2.

**After spikes 1–3, stop and report.** These three are the foundation. If they all pass, we have justified confidence in the architecture before any GTK code. If any fail, the cost was hours, not weeks.

### Spike 4 — libghostty rendering inside a SwiftGtk widget (target: 1–2 days)

**Goal:** The big unknown. Get pixels on screen and one keystroke through.

**Steps:**
1. Pick **one** binding for the spike. Try SwiftGtk first (closer to the metal, more documented). If it can't reach `GtkGLArea`'s `realize`/`render` signals cleanly, try Adwaita-Swift.
2. Stand up a minimal `GtkApplicationWindow` with a `GtkGLArea` child.
3. In the `realize` handler: `ghostty_app_new`, `ghostty_surface_new` with config pointing at the GL context. (Reference: `src/apprt/gtk/Surface.zig` `realize`.)
4. In the `render` handler: `ghostty_surface_draw`.
5. Connect `key-pressed-event` → `ghostty_surface_key`. (Reference: `src/apprt/gtk/Surface.zig` key handling.)
6. Boot a shell into it (`/bin/sh -c "echo hello; sleep 60"`). Confirm "hello" renders.
7. Type into it. Confirm characters reach the shell.

**Pass:** pixels appear, one keystroke round-trips. Quality doesn't matter — no IME, no resize, no mouse needed. Just proof the bridge exists.
**Fail:** report exactly where it broke. Likely failure modes: SwiftGtk doesn't expose `GtkGLArea` signals as Swift closures cleanly; libghostty expects a GL context shape the binding can't produce; the C callback table can't be populated from Swift the way `GhosttyCallbacks.swift` does on macOS.

**This is the project's life-or-death gate.** If spike 4 fails, the pure-Swift path is not viable and we revisit the language decision. Do not push through.

### Spike 5 — Sidebar feasibility on Adwaita-Swift (target: 1 day)

**Goal:** Confirm the most idiosyncratic agterm UI can be built in the chosen Swift+GTK stack.

**Steps:**
1. Using whichever binding won spike 4, build a non-functional sidebar: `AdwNavigationSplitView` (or equivalent) with a `GtkListView` showing a hardcoded list of two workspaces, each with three sessions.
2. Style it to look approximately like the macOS sidebar — disclosure triangles, indentation, selection highlight.
3. Confirm the binding lets you drive selection state from a Swift `@Observable` (or whatever reactive pattern the binding supports).

**Pass:** it looks roughly right and selection state is drivable from Swift. We don't need drag-reorder, flagging, or focus filter — those are extension work.
**Fail:** report what's missing in the binding. If basic list virtualization or two-level hierarchy isn't supported cleanly, the rest of the UI work gets expensive fast.

**After spike 5, stop and write a feasibility verdict.** Pass/pass/pass means we propose a real target plan with milestones. Anything else means we reconsider.

## Repo / build context for the Linux agent

- This repo lives at `/Users/alex/Developer/tries/2026-06-28-agterm` on the maintainer's Mac. The agent on Linux will clone it fresh.
- `GhosttyKit.xcframework`, `agterm/Resources/ghostty`, `agterm/Resources/terminfo` are gitignored build outputs from `scripts/setup.sh` — they are macOS-specific and the Linux agent should ignore them entirely. The Linux libghostty build is its own thing (spike 1).
- `agtermCore/` is a standalone SwiftPM package — no Xcode required. This is what spikes 2 and 3 build against.
- `scripts/`, `Makefile`, `project.yml`, the entire `agterm/` app target — all macOS-specific. The Linux agent should not touch them in spikes; they remain the macOS build's source of truth.
- The control protocol is documented by reading `agtermCore/Sources/agtermCore/ControlProtocol.swift` (the `Command` enum is the catalog) and `agterm/Resources/agent-skill/reference.md` (the user-facing surface).

## Open decisions to flag, not resolve yet

These come up only after spikes 1–4 pass; surface them in the spike-4 report, do not pre-decide:

1. **Repo layout:** new `agterm-linux/` target in this repo, or sibling repo? Shared repo means one source of truth for `agtermCore` but a more complex build matrix.
2. **SwiftGtk vs Adwaita-Swift:** spike 4 will give us empirical input. Decide after.
3. **Minimum target:** GTK4 + libadwaita 1.5+ (modern, GNOME 46+) is the likely answer. Confirm after spike 5.
4. **Distribution:** flatpak (ghostty's choice), AppImage, plain tarball, distro packages. Defer until there's something to distribute.

## What "done" looks like for this handoff

Linux agent reports back with:
- Spike 1, 2, 3 results (pass/fail each, with diagnostic detail on any fail).
- If 1–3 pass: spike 4 result, plus a recommendation on SwiftGtk vs Adwaita-Swift.
- If 4 passes: spike 5 result, plus a feasibility verdict and a proposed milestone plan.

Stop and check in at each gate. Do not write production code during spikes — throwaway is the point.

## Spike results log

### Environment (the Linux box)

Arch Linux, x86_64, 32 cores. Toolchain via `mise` (the maintainer's choice):
- `zig@0.15.2` — installs clean.
- `swift@6.3.2` — swift.org has no Arch build, so mise's distro-derived URL 404s. Use `MISE_SWIFT_PLATFORM=ubuntu24.04` + `mise settings experimental=true`; Arch's newer glibc runs the Ubuntu toolchain fine. The Ubuntu binaries need two no-sudo compat symlinks on `LD_LIBRARY_PATH`: `libncurses.so.6` → `/usr/lib/libncursesw.so.6` (Arch ships only the wide variant) and `libxml2.so.2` → `/usr/lib/libxml2.so.16` (SwiftPM uses libxml2's stable subset). lldb-only libs (libedit/libform/libpanel/libpython3.12) are irrelevant to headless build/test.
- System deps already present for the libghostty build: pkg-config, fontconfig, freetype2, harfbuzz, gtk4.

### Spike 1 — libghostty builds for Linux — PASS

The real flag is `zig build -Dapp-runtime=none` (the handoff's `-Demit-shared-lib=true` does not exist in this ghostty). `app_runtime=.none` is the default and emits the embedded C library — the same apprt macOS packages as the `.xcframework`. On non-Darwin it installs `zig-out/lib/ghostty-internal.{so,a}` + `zig-out/include/ghostty.h`. Built in ~45s. 89 exported `ghostty_` symbols. A trivial C consumer linked against the `.so` ran `ghostty_init` → `ghostty_info` (version `1.3.2-HEAD-+4dcb09a`, matching the pin) → `ghostty_config_new`/`finalize` → `ghostty_app_new` (returned a real app instance) → `ghostty_app_free`, clean exit 0.

Two packaging notes for the real build: the on-disk file is `ghostty-internal.so` but its ELF SONAME is `libghostty.so` (the loader needs that name — symlink it), and consumers link by exact filename (`-l:ghostty-internal.so`), since `-lfoo` expects `libfoo.so`.

### Spike 2 — agtermCore builds + tests on Linux — PASS

The `agtermCore` library compiles 100% clean — genuinely host-free, zero Darwin imports. `swift test` = **768/768 green** after the Linux deltas below. The only Darwin coupling in the whole package is in the `agtermctlKit` CLI (2 files), not the core.

### Spike 3 — agtermctl builds + runs on Linux — PASS

Builds and links. `--help` lists subcommands (exit 0); a no-server command fails cleanly (`connect(...) failed … — is agterm running?`, exit 1); a bad subcommand returns a usage error (exit 64). No crashes.

### Portability deltas found (fixed in a throwaway copy; the repo was left pristine)

1. `agtermctlKit` Darwin coupling — `SocketClient.swift` + `SocketClientTests.swift`: `import Darwin` → `#if canImport(Darwin) … #else import Glibc #endif`; keep `Darwin.connect`/`Darwin.accept` *module-qualified* per platform (instance methods named `connect`/`accept` shadow the C globals — dropping the prefix binds to the member, it is NOT arity-resolved to the syscall); `SOCK_STREAM` is the `__socket_type` enum on Glibc → `socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)`; the test helper's `fflush(stdout)` → `fflush(nil)` (Glibc `stdout` is a mutable global var → Swift 6 strict-concurrency error).
2. `ConfigPaths.editorCommand` defaults to `${SHELL:-/bin/zsh}` and 3 `ConfigPathsTests` hardcode `SHELL=/bin/zsh` (zsh absent on Arch → exit 127). The logic is portable (the impl supports bash/zsh/fish) — the Linux-equivalent test uses `/bin/bash` (+ `.bash_profile` for the rc-sourcing case).
3. The default socket/state path resolves to `~/Library/Application Support/agterm/agterm.sock` on Linux — `ControlResolve.socketPath`/`ConfigPaths` carry the macOS convention; the real port should use XDG.
4. `AgentStatusWrapperTests` 127s were a copy artifact (the test's `#filePath` reaches the app-target `agterm/Resources/agent-status/` sibling, which the package-only copy lacked) — the bash wrapper is portable and passes once the sibling exists.

**Verdict:** the shared core, control protocol, and CLI are portable, and libghostty's C ABI is fully callable from Linux. Proceeding to Spike 4 (the rendering gate).

### Spike 4 — libghostty rendering inside a GtkGLArea — BLOCKED (architectural)

The premise of this spike — "embed the SAME libghostty macOS uses and bind it to a `GtkGLArea` from Swift" — does NOT hold. The embedded apprt cannot create or render a surface on Linux, confirmed two ways:

- **Source:** in `src/apprt/embedded.zig`, the `Platform` union is `macos: MacOS` / `ios: IOS`, and both are `if (builtin.target.os.tag.isDarwin()) struct{…} else void`. `PlatformTag` only has `macos = 1`, `ios = 2`. On a non-Darwin build, `Platform.init` returns `error.UnsupportedPlatform` for every tag (and tag 0 fails `intToEnum`). The C ABI surface config (`ghostty_surface_config_s`) carries only `nsview`/`uiview`. There is no Linux/Wayland/X11/GL platform variant.
- **Empirically:** a C consumer linked against the Linux `.so` calls `ghostty_app_new` successfully, but `ghostty_surface_new` returns `nil` for both the default (invalid) tag and a `MACOS` tag with a non-null fake `nsview`. The app exists; a renderable surface cannot.

The reason: ghostty's OpenGL renderer (`renderer/OpenGL.zig`, used as `GenericRenderer(OpenGL)`) is real and works on Linux, but it is only wired up by the **GTK apprt** (`src/apprt/gtk/`, ~21,700 lines of Zig that builds as the `ghostty` *executable*, not a library). The GL-area↔renderer binding lives in `class/surface.zig` (`gl_area.makeCurrent()` → `core_surface.renderer.displayRealized()`; render → draw; unrealize → `displayUnrealized()`). None of that is exposed through the embeddable C ABI. The only library outputs are the embedded apprt (Apple-only surface) and `libghostty-vt` (terminal state, no renderer).

So no Swift+GtkGLArea code was written — it would have nothing to bind to. Per the handoff ("if spike 4 fails… revisit the language decision; do not push through"), stopping here for a decision.

**Paths forward (a real fork; needs the maintainer's call — none chosen):**
- **Path A — patch ghostty's embedded apprt to expose a Linux GL surface.** Add a context-less platform variant + `ghostty_surface_*` realize/render/unrealize that drive the already-working `CoreSurface` + `GenericRenderer(OpenGL)`, with the host (our Swift code) making the `GtkGLArea` context current before each call — mirroring what `class/surface.zig` already does. Reuses the proven renderer; estimated medium Zig effort (hundreds of lines), maintained as a patch against the pinned SHA or upstreamed. Cost: reintroduces Zig (which the maintainer wanted to avoid) and an upstream dependency, but keeps the "one embedded lib + thin Swift UI" shape.
- **Path B — build a renderer on `libghostty-vt`.** Use the VT/terminal-state lib + write the GL grid/font/cursor renderer ourselves in Swift. Very large (reimplements ghostty's renderer). Not recommended.
- **Path C — revisit the language decision** (what the handoff says to do on spike-4 failure): use ghostty's GTK apprt as-is (a Zig frontend) or the Swift-core + Rust/Zig-UI IPC split — the alternatives originally rejected for the one-language goal.

### Spike 4 / Path A — embedded libghostty renders on Linux — PROVEN

Path A was chosen and the core is proven: a small Zig patch to libghostty's embedded apprt makes it create and render an OpenGL surface on Linux into a host-owned GL context. A C harness with an offscreen EGL/OpenGL context (Mesa GL 4.6) booted a shell (`ls -la /usr/bin`) and ghostty rendered the real terminal — 384000/384000 background pixels + ~31k text-glyph pixels; the rendered framebuffer (saved to PPM/PNG) shows correctly-laid-out monospace text. `ghostty_surface_new(tag=opengl)` returns a valid surface where before it returned nil.

Upstream context: the embedded+OpenGL path was an explicit, acknowledged stub — `renderer/OpenGL.zig`'s `apprt.embedded` branches carried mitchellh's TODO *"libghostty is strictly broken for rendering on this platform."* Path A fills exactly those stubs.

The patch (against the pinned SHA, all in the scratchpad clone — throwaway spike):
1. `src/apprt/embedded.zig` — add a handle-free `opengl` `PlatformTag`/`Platform` variant carrying host callbacks (`userdata`, `make_current`, `present`); `Platform.init` accepts it (no nsview required).
2. `src/apprt/embedded.zig` — `App.must_draw_from_app_thread = build_config.renderer == .opengl`: on Linux, GL/glad state is threadlocal and the host owns the context, so the render thread only *requests* a draw (the `.render` action, already routed to the host on the embedded apprt) and the host calls `ghostty_surface_draw` on its own thread. Metal/macOS is unchanged (stays false).
3. `src/renderer/OpenGL.zig` — fill the `apprt.embedded` `surfaceInit` branch: call the host's `make_current`, then `prepareContext(null)` to load glad on the host thread.
4. `src/build/SharedDeps.zig` — also statically compile `vendor/glad/src/gl.c` for `step.kind == .lib and renderer == .opengl` (previously glad's loader was compiled only for executables, so the lib had an undefined `gladLoaderLoadGLContext`).
5. `include/ghostty.h` — add `GHOSTTY_PLATFORM_OPENGL` + the `ghostty_platform_opengl_s` union variant so the C ABI struct layout matches.

Host contract (what the Swift/GtkGLArea side must do): make its GL context current before `ghostty_surface_new` and before each `ghostty_surface_draw`; respond to `GHOSTTY_ACTION_RENDER` by drawing; swap/present after. This maps directly onto a `GtkGLArea`'s realize/render signals.

**Spike 4 sub-steps — all PASSED:**
- **Keystroke round-trip** (raw EGL): ran `cat`, injected keys via `ghostty_surface_key`; the echoed text appeared (proven by a before/after bright-pixel jump + screenshot showing the typed line echoed twice — tty echo + cat output).
- **Real `GtkGLArea`** (GTK4/Wayland, C): a GTK4 window with a `GtkGLArea` rendered ghostty (`ls -la /usr/lib`) at HiDPI scale 2. The `GdkGLContext` main-thread concern was handled by the app-thread-draw model — no threading workarounds needed. Event loop: `wakeup → g_idle tick → .render action → gtk_gl_area_queue_render → render signal → ghostty_surface_draw`.
- **Swift host**: a SwiftPM package (raw C interop over GTK4 + the patched ghostty) created the window, surface, and rendered — proving Swift can be the port language. Friction noted: GTK4's GObject types import as distinct typed Swift pointers (manual casts between `GtkWidget`/`GtkGLArea`/… via `OpaquePointer`), some types are opaque (`GtkEventController` → `OpaquePointer`), GTK macros (`G_CALLBACK`, `GTK_WINDOW`, `GDK_KEY_*`) and epoxy's GL macros are invisible to Swift (use `g_signal_connect_data` + `unsafeBitCast`, raw keyval constants). Workable for the low-level surface widget, but argues for a higher-level binding (SwiftGtk / Adwaita-Swift) for the declarative UI — see Spike 5.

**Spike 4 verdict: PASS.** The pure-Swift Linux path is viable. Cost: a maintained ~5-edit Zig patch to libghostty's embedded apprt (ideally upstreamed — it completes mitchellh's own `apprt.embedded` OpenGL TODO). Spike artifacts in the scratchpad: `spike4_surface_probe.c`, `spike4_egl_test.c` (+`spike4_frame.png`), `spike4_input_test.c` (+`spike4_input_after.png`), `spike4_gtk_test.c` (+`spike4_gtk.png`), `spike4-swift/`.

### Spike 5 — Sidebar feasibility on Adwaita-for-Swift — PASS (with a binding caveat)

Built the agterm two-level workspace → session sidebar with **Adwaita for Swift** (`AparokshaUI/Adwaita` 0.2.6) on libadwaita 1.9: `NavigationSplitView` (= `AdwNavigationSplitView`) + a per-workspace nested `List(elements, selection: $state)`. The screenshot (`scratchpad/spike5_sidebar.png`) shows native libadwaita styling, the two-level hierarchy (Work: editor/server/logs; Personal: chat/music/notes), the selection highlight on the `@State`-selected row, and the content pane reflecting the bound `@State` (`selected session id: s1`). Selection is drivable from Swift `@State` — pass criterion met. (Drag-reorder/flagging/focus-filter were explicitly out of scope.)

The binding (declarative, SwiftUI-like `@State`/`View`/`List`) is expressive and the sidebar maps cleanly. **Caveat (the predicted "immature bindings" risk):** Adwaita 0.2.6 does not compile against glib 2.88 out of the box — glib's flag enums (`GConnectFlags`, `GApplicationFlags`) are now `G_GNUC_FLAG_ENUM`, so Swift imports them as OptionSet structs and the bare `G_CONNECT_AFTER` / `G_APPLICATION_DEFAULT_FLAGS` the binding uses are gone. An ~8-line compat patch (2 symbols → `(rawValue:)`) fixes it; after that the sidebar builds and runs cleanly. Implication: pin a binding version known to build on the target glib, contribute the compat fix upstream, or vendor a patched copy.

## Feasibility verdict: VIABLE — all five spikes pass

The pure-Swift Linux/GTK port is feasible. ~56% of the code (all of `agtermCore` + `agtermctl`) reuses as-is. Two new load-bearing dependencies, both with small, well-understood costs:
1. **A Zig patch to libghostty's embedded apprt** adding a handle-free OpenGL surface for Linux (Path A; ~5 edits; reuses ghostty's existing `CoreSurface`+`GenericRenderer(OpenGL)`; ideally upstreamed since it completes an existing TODO).
2. **A Swift GTK binding** — Adwaita-for-Swift for the declarative shell, needing a small glib-compat patch (or a maintained newer version).

**Architecture recommendation:** Adwaita-for-Swift for the app shell (sidebar → `AdwNavigationSplitView`, settings → `AdwPreferencesWindow`, palettes → `GtkPopover`/`SearchEntry`, all driven by `AppStore` bridged `@Observable`→`@State`); the **terminal surface widget stays raw `GtkGLArea` C interop** (spike 4 pattern — do NOT try to build it in the declarative binding). This mirrors macOS, where `GhosttySurfaceView` is hand-written `NSView`+Metal, not SwiftUI.

### Proposed milestone plan
- **M0 — libghostty Linux surface:** upstream (or vendor in `scripts/setup.sh`) the embedded-apprt OpenGL patch; produce a reproducible Linux `libghostty.so` build.
- **M1 — one terminal on screen:** `agterm-linux` target links patched libghostty; `GhosttySurfaceWidget` (`GtkGLArea`) conforms to `TerminalSurface`; reimplement `GhosttyCallbacks` against `g_main_context_invoke`. A single working shell in a GTK window.
- **M2 — app shell:** `AdwApplicationWindow` + `AdwNavigationSplitView` sidebar bound to `AppStore`; the multi-session deck; tabs/splits.
- **M3 — control surface:** `ControlServer` accept loop on a GLib source; reuse `agtermctl` verbatim; notifications via libnotify / `org.freedesktop.Notifications`.
- **M4 — settings & input:** `AdwPreferencesWindow` settings, keymap, command/theme palettes, multi-window restore.
- **M5 — distribution:** flatpak packaging + CI matrix.

### Open decisions (now answerable)
- **Repo layout:** a sibling `agterm-linux/` target in THIS repo, sharing `agtermCore` (one source of truth) — the spikes confirmed `agtermCore` is genuinely shareable.
- **Binding:** Adwaita-for-Swift (declarative) + raw C interop for the surface.
- **Minimum target:** GTK4 + libadwaita ≥ 1.5 (this box: 4.22 / 1.9).
- **Distribution:** flatpak (ghostty's choice), defer until M5.

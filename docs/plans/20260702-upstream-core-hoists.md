# Upstream core hoists status

Goal: keep `agtermCore` host-free and shared, with platform-specific code staying in the app/UI layer
whenever possible. Upstream PRs should have direct macOS value: add or refine shared core, add focused
tests, and rewire the macOS call site in the same PR. Do not upstream the Linux frontend as part of
these slices.

Manager rule: worker sessions stop after local validation and report branch/commit/results. Do not push
or open a PR unless Alex explicitly approves that step.

## Current checkpoint - 2026-07-05

- The earlier upstream slicing pass is merged through:
  - keymap/config loading
  - overlay capture constants
  - custom command matching
  - palette catalog
  - control resolve messages and mode helpers
  - fuzzy rank, theme catalog, surface environment, window control metadata/resolution,
    keystroke segmentation
  - AppStore control-tree/sidebar helpers
  - ControlDispatcher foundation, session/workspace groups, session text/background/restore,
    and the focused window-control set
- `linux-port` has been rebased onto upstream and the Linux app now consumes upstream `agtermCore`
  directly enough to build and run.
- Local validation after the Linux rebase:
  - `cd agtermCore && swift test` passes: 1167 tests.
  - `./scripts/run-linux.sh` builds and launches `AgtermLinux`.
  - `swift run agtermctl tree --socket /home/sasha/.local/share/agterm/agterm.sock` returns the
    running Linux app's workspace/session tree.
- Remaining Linux-only helpers have been kept in `agterm-linux` compatibility code instead of being
  reintroduced into `agtermCore`.

## Upstream TODOs

### 1. ControlDispatcher synchronous route

Upstream a small shared dispatcher refinement:

- Add `ControlDispatcher.dispatchSync(_:)`.
- Keep `ControlActions.typeSession(...)` async and keep `dispatch(_:)` async for macOS.
- Exclude `session.type` from `dispatchSync(_:)`; hosts that need synchronous control dispatch should
  handle that one command inline or use the async dispatcher.

Why: the GTK control server is already on the GTK main loop and cannot safely hop through Swift
concurrency from the C callback path. The sync dispatcher route lets Linux use the shared controller
without changing macOS's async text-injection behavior.

Validation:
- Core dispatcher tests.
- macOS build/control tests.
- Linux smoke: `agtermctl tree` against a running Linux app.

### 2. agtermctlKit POSIX socket portability

Upstream `agtermctlKit` portability:

- Change `SocketClient.swift` from hard-coded `Darwin` to conditional `Darwin` / `Glibc`.
- Update `SocketClientTests.swift` socket helpers the same way.
- Use `fflush(nil)` in the stdout-capture helper so Swift 6 on Linux does not reject direct `stdout`
  global access.

Why: `agtermctl` is part of the shared control surface and should build on Linux.

Validation:
- `cd agtermCore && swift test`.
- `swift run agtermctl tree --socket ...` against the Linux app.

### 3. Test portability cleanup

Upstream the `ConfigPathsTests` portability fix:

- Do not assume `/bin/zsh` exists for generic editor-command quoting tests; use `/bin/sh`.
- Gate the zsh-rc-specific test on `/bin/zsh` being executable.

Why: the shared core test suite should run on Linux without weakening the zsh-specific coverage when zsh
is available.

Validation:
- `cd agtermCore && swift test` on Linux.
- Existing macOS test run should still execute the zsh-specific case.

## Do not upstream now

Keep these as Linux-local compatibility shims unless a future PR removes macOS duplication or creates a
clear host-free contract:

- Linux default key chords.
- Linux theme OSC glue and inline fallback theme data.
- Linux starter `ghostty.conf` / restore-denylist text.
- Linux window geometry no-op shims.
- Linux `/proc/<pid>/cmdline` parsing.
- Linux drag/drop payload decoding.
- Linux font binding action string constants, unless macOS has matching duplication that should be
  centralized.
- `addWorkspaceSeeded` and standalone `setPaneFocus`; they either encode Linux UI convenience behavior
  or still require platform first-responder work.
- Terminal notification delivery helpers; optional future polish only, not a control-surface blocker.

## Non-blocking maintainer follow-ups

Fold these in only if nearby code is already being touched:

- `readSessionText` still has validation/comment remnants from before the dispatcher owned validation.
- Window geometry tests could add mirror cases for missing width, height `0`, and missing x.

## PR framing

Use this framing for any remaining upstream PR:

> This is one host-free core extraction/refinement from the Linux-port work, scoped to macOS value. It
> moves shared control/tooling behavior into `agtermCore` or `agtermctlKit`, adds focused tests, and keeps
> platform UI code outside the shared core. It does not add the Linux frontend.

Include:

- What macOS/shared behavior changed.
- What core tests cover.
- Exact macOS validation performed.
- Confirmation that no Linux frontend files are included.

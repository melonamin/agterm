# Upstream core hoists PR plan

Goal: upstream the host-free `agtermCore` improvements without upstreaming the Linux frontend. Each PR
should stand on its own for macOS: add or refine the shared core module, add focused core tests, and
rewire the macOS call site in the same PR.

Baseline: current `linux-port` has one large core commit plus a tiny macOS split-pane fix. The Linux app
commits should not be part of upstream PRs. The untracked `scripts/flatpak-linux.sh` is unrelated.

Validation note: this environment does not have `swift`, Xcode, or GhosttyKit, so the plan below still
requires macOS validation before opening each upstream PR.

## PR 0 - rebase and branch hygiene

Purpose: prepare clean upstreamable slices.

Scope:
- Rebase onto current `origin/master`.
- Drop all Linux frontend, packaging, CI, and Linux docs from upstream branches.
- Keep the fork's Linux branch separate as the consumer/proof of the shared APIs.
- Create one working branch per PR below from fresh upstream.

Validation:
- `git diff --name-status origin/master...HEAD` for each branch should show only the relevant
  `agtermCore`, `agterm`, and test files.

## PR 1 - small config/keymap loading hoist

Why first: low risk, obvious macOS benefit, and proves the PR pattern the maintainer asked for.

Scope:
- `agtermCore/Sources/agtermCore/ConfigPaths.swift`
  - Add `starterKeymapConf()` if it is not already present on the target branch.
- `agtermCore/Sources/agtermCore/Keymap.swift`
  - Add `KeymapStore`.
- `agterm/SettingsModel.swift`
  - Replace direct file read plus `parseKeymap` with `KeymapStore(...).load()`.
  - Replace or delete `starterKeymapText()` by using `ConfigPaths.starterKeymapConf()`.

Keep out:
- Linux default key tables.
- `agtermctlKit` XDG socket/path changes.
- Linux-only copy-on-select settings.

Tests:
- Core tests for missing keymap file, unreadable/malformed file recovery, and starter keymap parsing.
- macOS: build the app, open Settings -> Key Mapping, reload keymap, verify diagnostics still surface.

Risk: low.

## PR 2 - overlay exit capture constants

Why second: very small behavioral surface, removes literal duplication, and validates `session.overlay`
without touching the control dispatcher.

Scope:
- Add `agtermCore/Sources/agtermCore/OverlayCapture.swift`.
- Rewire `agterm/agtermApp.swift` overlay command setup:
  - use `OverlayCapture.cmdEnvKey`
  - use `OverlayCapture.codeEnvKey`
  - build the wrapper from `OverlayCapture.shellLine`
  - parse the exit-code file via `OverlayCapture.parseExitCode`

Tests:
- Core tests for the shell line constants and exit-code parsing.
- macOS: run `agtermctl session overlay open ... --block` and verify the reported exit code.

Risk: low.

## PR 3 - custom-command matcher hoist

Why here: still small, but now touches a keyboard path.

Scope:
- Add `agtermCore/Sources/agtermCore/CustomCommandEngine.swift`.
- Rewire `agterm/Commands/CustomCommandRunner.swift`:
  - replace `KeybindMatcher` plus `commandsByID` with `CustomCommandEngine`
  - keep the macOS event conversion, context resolution, leader timer, and process spawn unchanged

Tests:
- Core tests for fired, armed, unmatched, reset, and palette-only commands.
- macOS: existing custom-command UI/keymap tests.

Risk: low to medium.

## PR 4 - palette catalog hoist

Why after custom commands: more UI-facing, but still mostly static data and visibility predicates.

Scope:
- Add `agtermCore/Sources/agtermCore/PaletteCatalog.swift`.
- Rewire `agterm/AppActions.swift` `paletteActions()`:
  - iterate `PaletteCommand.allCases` for static built-in palette entries
  - map commands to macOS closures with an exhaustive switch
  - use `PaletteContext` for static visibility rules
- Keep platform-specific/dynamic rows in macOS:
  - open/rename/delete window
  - move session to workspace
  - custom commands
  - focus/clear focus if it remains macOS-only in current UI semantics

Tests:
- Core tests for command titles and visibility.
- macOS palette tests for clear-flagged and expand/collapse visibility.

Risk: medium. The main risk is changing the palette order or accidentally dropping a dynamic row.

## PR 5 - resolution/error-message cleanup

Why separate: tiny cleanup, but best landed before the dispatcher so tests pin one canonical error path.

Scope:
- Extend `ControlResolve` with `notFoundMessage` and `ambiguousMessage` helpers.
- Rewire `agterm/Control/ControlServer.swift` `resolutionError(...)` to use those helpers.

Tests:
- Core tests for exact error strings.
- Existing control API tests.

Risk: trivial.

## PR 6 - control protocol helpers, no dispatcher yet

Why separate: `BinaryControlMode`, `PaneFocusMode`, and small store helpers reduce the later dispatcher
diff without changing the main dispatch switch.

Scope:
- Add pure helpers:
  - `BinaryControlMode`
  - `PaneFocusMode`
  - any small `ControlResolve` validation helpers used by existing macOS control commands
- Rewire existing macOS command arms where the helper is a direct drop-in:
  - split/scratch/sidebar/status mode parsing
  - pane focus parsing

Keep out:
- `ControlDispatcher`
- window command migration
- Linux-only control behavior

Tests:
- Core tests for mode parsing and invalid-mode errors.
- Existing control API tests must keep exact response strings.

Risk: low to medium. It touches control behavior, but keeps the old switch structure.

## PR 7 - AppStore pure operation helpers

Why before dispatcher: the dispatcher should call small core operations instead of forcing reviewers to
review model changes and dispatch extraction together.

Scope:
- Hoist only AppStore methods with direct macOS use:
  - `addWorkspaceSeeded`
  - `setPaneFocus`
  - notification/status helpers if used by macOS control or UI paths
  - `controlTree(foreground:)`
  - flag/sidebar/focus helpers that replace duplicated macOS logic
- Rewire macOS call sites opportunistically where the replacement is one line and covered by tests.

Keep out:
- Window geometry changes unless needed by current macOS window commands.
- Linux-specific defaults and UI-only helpers.

Tests:
- AppStore unit tests for each new model operation.
- Existing macOS UI/control tests for sidebar, flagged view, notification counts, and tree output.

Risk: medium. Review carefully for observation/reconcile side effects.

## PR 8 - ControlDispatcher, command group 1

Why not one giant dispatcher PR: the maintainer explicitly called this the risky part. Split it by command
families and leave the old switch as fallback while migrating.

Scope:
- Add `ControlDispatcher` and `ControlActions` with only the command families in this PR.
- Start with low-side-effect command groups:
  - `tree`
  - `workspace.select/new/rename/delete`
  - `session.select/go/close/rename`
  - `sidebar.*`
- Add a macOS `ControlActions` adapter around existing `ControlServer`/`AppActions`/`AppStore` seams.
- In `ControlServer.dispatch`, route only these commands through `ControlDispatcher`; keep all other
  command arms inline.

Tests:
- Core dispatcher tests with `MockControlActions`.
- Existing macOS control e2e tests for the migrated commands.
- Manual macOS smoke: create/rename/delete workspace and session from `agtermctl`.

Risk: medium.

## PR 9 - ControlDispatcher, command group 2

Scope:
- Migrate session mutation commands:
  - `session.new`
  - `session.move`
  - `workspace.move`
  - `workspace.focus`
  - `session.flag`
  - `session.status`
  - `session.split`
  - `session.scratch`
  - `session.focus`
  - `session.resize`

Tests:
- Core dispatcher tests for success and exact invalid-mode errors.
- Existing macOS control e2e and UI tests around split/scratch/focus/sidebar.

Risk: medium to high. This is where reconcile/selection behavior can drift.

## PR 10 - ControlDispatcher, command group 3

Scope:
- Migrate commands that need platform side effects:
  - `session.type`
  - `session.selection`
  - `font.*`
  - `keymap.reload`
  - `config.reload`
  - `notify`
  - `theme.*`
  - `session.overlay.*` if PR 2 has already landed

Keep inline:
- Commands that the handoff identified as intentionally platform-specific:
  - `session.search`
  - `window.move`
  - `restore.clear`
  - any quit-confirm/reveal behavior still tied to AppKit

Tests:
- Existing control e2e for typing, selection, font size, reload, theme, notify, overlay.
- Manual macOS overlay `--block` check.

Risk: high. This is the user-visible command/control path.

## PR 11 - window-library control support

Why late: window ownership and AppKit behavior are more likely to conflict with active upstream work.

Scope:
- Hoist only window metadata/control helpers that macOS actually uses:
  - `WindowGeometry.Size: Codable` if needed
  - `WindowLibrary.controlWindowNodes()`
  - `resolveWindow(...)`
  - `setGeometry(...)` only if the macOS command path persists this state
- Rewire macOS window commands that can safely use the helper:
  - `window.new`
  - `window.close`
  - `window.resize`
  - possibly `window.list/tree` pieces

Keep out:
- Linux GTK window manager assumptions.
- Any change to `window.move` unless explicitly requested by the maintainer.

Tests:
- WindowLibrary unit tests.
- macOS control e2e for `window.*`.

Risk: medium to high.

## PR 12 - optional pure utility hoists

Only do these after the maintainer has accepted several prior hoists. They are useful, but less central
to the maintainer's explicit ask.

Candidates:
- `Fuzzy.fuzzyRank`
- `KeystrokeSegments`
- `PasteDecoder`
- `DeletePrompt`
- `SessionSwitcherModel`
- `SurfaceEnvironment`
- `ThemeCatalog` if the macOS theme picker can use it directly
- `GhosttyResourceResolver` and `GhosttyDefaults` only if macOS has matching duplicate logic
- `ThemeColorResolver` only if macOS starts using it; current macOS appears to use AppKit color blending

Rule: do not upstream a helper just because Linux uses it. Upstream it when the PR removes macOS
duplication or makes macOS behavior more testable.

## Suggested opening order

1. PR 1 - ConfigPaths/KeymapStore/starter keymap
2. PR 2 - OverlayCapture
3. PR 3 - CustomCommandEngine
4. PR 4 - PaletteCatalog
5. PR 5 - ControlResolve messages
6. PR 6 - Control protocol mode helpers
7. PR 7 - AppStore pure operation helpers
8. PR 8 - ControlDispatcher group 1
9. PR 9 - ControlDispatcher group 2
10. PR 10 - ControlDispatcher group 3
11. PR 11 - WindowLibrary control support
12. PR 12 - optional pure utilities, one at a time

## PR description template

Use this framing for each upstream PR:

> This is one host-free core extraction from the Linux-port work, but the PR is scoped to macOS value:
> it moves duplicated app logic into `agtermCore`, adds unit tests, and rewires the macOS call site onto
> the shared implementation. It does not add the Linux frontend.

Include:
- What macOS logic was removed or rewired.
- What core tests cover.
- Exact macOS validation performed.
- Confirmation that no Linux frontend files are included.

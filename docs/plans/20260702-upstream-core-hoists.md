# Upstream core hoists PR plan

Goal: upstream the host-free `agtermCore` improvements without upstreaming the Linux frontend. Each PR
should stand on its own for macOS: add or refine the shared core module, add focused core tests, and
rewire the macOS call site in the same PR.

Baseline: current `linux-port` has one large core commit plus a tiny macOS split-pane fix. The Linux app
commits should not be part of upstream PRs. The untracked `scripts/flatpak-linux.sh` is unrelated.

Validation note: this environment can run `swift`, `xcodegen`, and Xcode builds after `scripts/setup.sh`
stages GhosttyKit/resources. Manual app behavior checks are still required where a PR calls them out.

Manager rule: worker sessions should stop after local validation and report the branch/commit/results.
Do not push or open a PR unless Alex explicitly approves that step for the specific branch.

Progress update 2026-07-02:
- PR 1 merged as PR #78 from `upstream-keymap-store`.
- PR 2 merged as PR #79 from `upstream-overlay-capture`.
- Local validation for PR 2: `swift test --filter OverlayCaptureTests`, full `cd agtermCore && swift test`
  (724 tests), `make lint`, `scripts/setup.sh`, `xcodegen generate`, Debug `xcodebuild`, focused
  overlay XCUITests (10 tests), and a live `agtermctl session overlay open ... --block` smoke all pass.
- PR 3 merged as PR #81 from `upstream-custom-command-engine`.
- Local validation for PR 3: `swift test --filter CustomCommandEngineTests`, full
  `cd agtermCore && swift test` (730 tests), `make lint`, `scripts/setup.sh`, `xcodegen generate`,
  Debug `xcodebuild`, focused `KeymapUITests` (8 tests), and `codex review --base upstream/master`
  all pass.
- PR 4 merged as PR #83 from `codex/upstream-palette-catalog`.
- PR 4 commit: `97b9150 refactor(palette): hoist static command catalog`.
- Local validation for PR 4: `swift test --filter PaletteCatalogTests`, full
  `cd agtermCore && swift test` (730 tests), `make lint`, `scripts/setup.sh`, `xcodegen generate`,
  Debug `xcodebuild`, focused new `PaletteUITests` visibility checks, and
  `codex-review --mode branch --base origin/master --parallel-tests "cd agtermCore && swift test --filter PaletteCatalogTests"`
  all pass. A full `PaletteUITests` run was attempted and failed in three older
  menu/rename/navigation tests while the new visibility tests passed on rerun.
- PR 5 merged as PR #84 from `codex/upstream-control-resolve-messages`.
- PR 5 commit: `a31f9ba refactor(control): hoist resolution error messages`.
- Local validation for PR 5: focused `ControlResolveTests`, full `cd agtermCore && swift test`
  (725 tests), `make lint`, `make build`, and focused `ControlAPIUITests` for exact not-found and
  ambiguous-prefix resolution errors all pass. `make build` emitted existing `ContentView.swift`
  implicit strong-capture warnings but completed successfully.
- PR 6 is locally ready on `codex/upstream-control-mode-helpers`.
- PR 6 commit: `c5dec2b refactor(control): hoist mode parsing helpers`.
- Local validation for PR 6: focused `ControlModesTests`, full `cd agtermCore && swift test`
  (730 tests), `make lint`, `make build`, and focused `ControlAPIUITests` for the rewired sidebar,
  split, scratch, pane-focus, and quick-terminal branches all pass.

Progress update 2026-07-03:
- PR 6 merged as PR #94 from `codex/upstream-control-mode-helpers`.
- Additional small upstream slices merged:
  - PR #91 `codex/upstream-fuzzy-rank`: fuzzy ranking.
  - PR #92 `codex/upstream-theme-catalog`: theme catalog facts.
  - PR #93 `codex/upstream-window-library-control-nodes`: window list metadata.
  - PR #103 `codex/upstream-surface-environment`: surface environment builders.
  - PR #104 `codex/upstream-window-resolve-helper`: window target resolution.
  - PR #106 `codex/upstream-keystroke-segments`: keystroke segmentation.
  - PR #107 `codex/upstream-appstore-operation-helper`: sidebar visibility operation helper.
  - PR #108 `codex/upstream-appstore-control-tree`: app store tree projection.
- At this checkpoint, PR #105 `codex/upstream-control-dispatcher-foundation` was open, approved, and
  green after the post-#107/#108 rebase.
- Do not start broad Linux frontend work from this plan. The remaining upstreamable work should stay in
  focused macOS-value slices, with each worker stopping after local validation unless Alex approves
  opening/pushing that PR.

Progress update 2026-07-03 later:
- PR #105 `codex/upstream-control-dispatcher-foundation` merged.
- PR #114 `codex/upstream-control-dispatcher-group-2` merged.
- PR #119 `codex/upstream-control-dispatcher-group-3a` merged.
- Research checkpoint after #119: continue current slicing, but do not jump straight to Linux UI
  integration after 3b. First backfill any still-inline session/workspace dispatcher commands that
  upstream has not migrated, then consider small follow-ups for `session.text`, `session.background`,
  and `restore.clear`, then window command cleanup.

Progress update 2026-07-05:
- PR #120 `codex/upstream-control-dispatcher-group-3b` merged.
- PR #124 `codex/upstream-control-dispatcher-backfill` merged.
- PR #128 `codex/upstream-control-dispatcher-session-text-restore` merged.
- PR #132 `codex/upstream-control-dispatcher-window-controls` merged.
- Dispatcher slicing is now through the session/workspace backfill, text/background/restore controls,
  and the first focused window-control set. The next upstreamable target should be a single focused
  audit of all remaining inline control commands, not a long tail of tiny dispatcher PRs. The likely
  migrated set is the host-free parts of `window.new`, `window.list`, `window.select`, `window.close`,
  and `window.delete`. The same worker should explicitly inspect `session.search`, `quick`, and the
  cache-only fast paths for `window.list` / `tree --window`; migrate them only if the seam is clean and
  behavior-preserving, otherwise document why they stay inline.
- AppStore-helper audit against `linux-port` found no standalone helper slice that should block the
  Linux UI rebase after the inline-command cleanup. `controlTree`, sidebar visibility/mode, session
  placement, split/scratch/overlay store operations, status/background, auto-follow, and window metadata
  are already represented upstream in stronger or equivalent forms. `addWorkspaceSeeded` is a Linux UI
  convenience and would change macOS empty-workspace behavior if used upstream. `setPaneFocus` is too
  small as a pure store helper and the important first-responder behavior stays app-side. A terminal
  notification delivery helper (`NotificationDelivery`/`TerminalNotificationRecord` plus an
  `AppStore.recordTerminalNotification` wrapper) is the only plausible optional follow-up, but it is not
  a control-surface blocker and should not be mixed into the dispatcher/window cleanup.
- Linux rebase checkpoint: once the upstream dispatcher/control surface is present on `master`, the
  Linux branch should drop its old shared-controller implementation and consume upstream `agtermCore`
  directly. If the Linux UI still references pure helpers that were never upstreamed, keep them as
  Linux-local compatibility shims under `agterm-linux` rather than reintroducing them into `agtermCore`.
  Those helpers are candidates for later upstream PRs only when they remove macOS duplication, preserve
  exact macOS behavior, and can be reviewed as small host-free slices. They are not blockers for the
  Linux UI rebase.
- Non-blocking maintainer follow-ups to fold in only if nearby code is touched:
  - From PR #128: `readSessionText` still carries validation and a stale raw-socket comment even though
    the dispatcher owns that validation now.
  - From PR #132: invalid window geometry tests could add mirror cases for missing width, height `0`,
    and missing x.

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

Status: merged as PR #78 from `upstream-keymap-store`.

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

Status: merged as PR #79 from `upstream-overlay-capture`.

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

Status: merged as PR #81 from `upstream-custom-command-engine`.

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

Status: merged as PR #83 from `codex/upstream-palette-catalog`.

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

Status: merged as PR #84 from `codex/upstream-control-resolve-messages`.

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

Status: merged as PR #94 from `codex/upstream-control-mode-helpers`.

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

Status: effectively complete for the current upstream slicing pass.
- PR #107 merged `setSidebar`/sidebar visibility operation support.
- PR #108 merged `controlTree(foreground:)`/tree projection support.
- Remaining AppStore helper candidates should not be queued as standalone PRs. Fold one in only when a
  nearby dispatcher/control slice needs it and the macOS call site clearly gets smaller or more testable.
  For example, `setPaneFocus` is not a clean pure store operation today: the parser is already in core,
  while the action still needs app-side first-responder focus behavior.

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

Status: merged as PR #105 from `codex/upstream-control-dispatcher-foundation`.

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

Status: merged as PR #114 from `codex/upstream-control-dispatcher-group-2`.

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

## PR 10a - ControlDispatcher, command group 3a

Status: merged as PR #119 from `codex/upstream-control-dispatcher-group-3a`.

Scope:
- Migrate lower-risk platform/control side-effect commands:
  - `font.*`
  - `keymap.reload`
  - `config.reload`
  - `notify`
  - `theme.*`

Tests:
- Existing control e2e for font size, reload, theme, and notify.
- Focused dispatcher tests for success and exact error responses.

Risk: medium to high. These touch app-side side effects, but are less coupled than typing, selection,
and overlay.

## PR 10b - ControlDispatcher, command group 3b

Status: merged as PR #120 from `codex/upstream-control-dispatcher-group-3b`.

Scope:
- Migrate remaining commands that need heavier platform side effects:
  - `session.type`
  - `session.selection`
  - `session.overlay.*`

Tests:
- Existing control e2e for typing, selection, and overlay.
- Manual macOS overlay `--block` check.

Risk: high. This is the user-visible command/control path.

## PR 10c - ControlDispatcher backfill

Why after 3b: once the high-risk side-effect commands are migrated, audit the remaining inline
session/workspace control commands against the Linux-port shared controller and close the dispatcher
surface gap before starting Linux UI integration.

Status: merged as PR #124 from `codex/upstream-control-dispatcher-backfill`.

Scope:
- Audit `ControlServer.dispatch` for session/workspace commands still handled inline after PR 10b.
- Migrate only the commands that fit the existing `ControlDispatcher`/`ControlActions` seams and have
  clear macOS behavior coverage.
- Keep truly platform-specific commands inline and document why.

Keep out:
- Window ownership/AppKit commands.
- Linux UI code.
- Broad control-surface reshaping.

Tests:
- Focused dispatcher tests for each backfilled command.
- Existing macOS control tests for exact response strings and precedence.

Risk: medium. This should be mechanically smaller than 3b, but it is the final check that the shared
controller surface is complete enough for the later Linux UI.

## PR 10d - text/background/restore cleanup

Why separate: these commands are adjacent to the controller surface, but their behavior may be more
platform- or UI-specific than the core dispatcher backfill.

Status: merged as PR #128 from `codex/upstream-control-dispatcher-session-text-restore`.

Scope candidates:
- `session.text`
- `session.background`
- `restore.clear`

Rule:
- Only upstream these if the PR removes macOS duplication or pins behavior in host-free tests. If they
  are effectively Linux UI proof points, leave them for the Linux UI integration phase.

Risk: medium.

## PR 11 - window-library control support

Why late: window ownership and AppKit behavior are more likely to conflict with active upstream work.

Status: partially merged.
- PR #93 merged window list/control-node metadata.
- PR #104 merged window target resolution.
- PR #132 merged dispatcher routing for the focused window control command set.
- Remaining window command support should be audited now that dispatcher foundations have landed, but
  should still stay in small behavior-preserving slices.

Scope:
- Hoist only window metadata/control helpers that macOS actually uses:
  - `WindowGeometry.Size: Codable` if needed
  - `WindowLibrary.controlWindowNodes()`
  - `resolveWindow(...)`
  - `setGeometry(...)` only if the macOS command path persists this state
- Rewire macOS window commands that can safely use the helper:
  - `window.new`
  - `window.list`
  - `window.select`
  - `window.close`
  - `window.delete`
  - any related `tree --window` projection cleanup only if it is inseparable from the chosen slice

Keep out:
- Linux GTK window manager assumptions.
- Broad changes to `session.search`, `quick`, or cache-only fast paths unless the audit proves they are
  simple host-free routing cleanup.

Tests:
- WindowLibrary unit tests.
- macOS control e2e for `window.*`.

Risk: medium to high.

## PR 12 - optional pure utility hoists

Only do these after the maintainer has accepted several prior hoists. They are useful, but less central
to the maintainer's explicit ask.

Status: partially merged.
- Merged: `Fuzzy.fuzzyRank` (#91), `ThemeCatalog` (#92), `SurfaceEnvironment` (#103), and
  `KeystrokeSegments` (#106).
- Still candidates only if they remove macOS duplication or support a focused follow-up:
  `PasteDecoder`, `DeletePrompt`, `SessionSwitcherModel`, `GhosttyResourceResolver`,
  `GhosttyDefaults`, and `ThemeColorResolver`.

Candidates:
- `PasteDecoder`
- `DeletePrompt`
- `SessionSwitcherModel`
- `GhosttyResourceResolver` and `GhosttyDefaults` only if macOS has matching duplicate logic
- `ThemeColorResolver` only if macOS starts using it; current macOS appears to use AppKit color blending

Rule: do not upstream a helper just because Linux uses it. Upstream it when the PR removes macOS
duplication or makes macOS behavior more testable.

## Remaining opening order

1. PR 11 follow-up - audit all remaining inline control commands after the window dispatcher merge. Aim
   to make this the final dispatcher cleanup PR rather than splitting many tiny follow-ups. The likely
   migrated set is `window.new`, `window.list`, `window.select`, `window.close`, and/or
   `window.delete`. Also inspect `session.search`, `quick`, and cache-only fast paths; migrate them only
   if they have a clean behavior-preserving seam, otherwise document why they intentionally remain
   inline.
2. Do not schedule a standalone AppStore helper PR unless the inline-command audit uncovers a concrete
   macOS call site that gets simpler. The earlier AppStore work already landed as #107/#108. The
   remaining audited candidates are not blockers: skip `addWorkspaceSeeded`, skip standalone
   `setPaneFocus`, and treat terminal notification delivery as optional polish only.
3. Optional pure utilities one at a time, only when the PR removes macOS duplication or pins behavior:
   `PasteDecoder`, `DeletePrompt`, `SessionSwitcherModel`, or Ghostty resource/default helpers.
4. Rebase `linux-port` onto fresh upstream after the final dispatcher cleanup. Prefer upstream
   `agtermCore` over the branch's old shared-controller implementation. Any still-needed Linux-only pure
   helpers should live in the Linux frontend as compatibility shims, with comments or plan notes that
   they are local consumers/proof points, not automatic upstream targets.
5. Stop upstream slicing when the remaining candidates are Linux-only proof points rather than macOS
   simplifications.

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

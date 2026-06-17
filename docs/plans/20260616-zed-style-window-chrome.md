# Zed-style window chrome redesign

## Overview

Redesign agt's window chrome to resemble the Zed editor: a cohesive dark theme across the
sidebar, a custom integrated top header (replacing the native title bar), and a thin restyled
bottom status bar. The current chrome uses default macOS/SwiftUI styling (translucent
source-list sidebar, native title bar, plain bottom bar) which the user finds "boring and ugly".

Three areas, delivered in phases so each is built, launched, and visually confirmed before the
next:

1. **Sidebar** (`WorkspaceSidebar`, an AppKit `NSOutlineView`): dark-grey panel, denser rows,
   small leading SF-symbol icons (workspace vs session), refined text colors, and a **flat
   full-width accent selection** replacing the rounded source-list pill.
2. **Bottom status bar** (`ContentView.statusBar` + `GitStatusPill`): thin Zed-style bar, dark
   background, left-aligned info + right-aligned git indicators.
3. **Title bar** (new): replace the native macOS title bar with a custom integrated dark header
   showing a `workspace › session` breadcrumb, with the traffic lights overlaid inside it and
   content sitting below — implemented as an AppKit `NSTitlebarAccessoryViewController` with
   `layoutAttribute = .top`.

### Confirmed decisions (from user)

- **Git status placement**: stays in the **bottom status bar** (not moved to the header).
- **Palette**: Zed-like fixed dark greys for panels; **selection follows the system accent**
  (`NSColor.controlAccentColor`) — adaptive, not a hardcoded blue.
- **Header identity**: `workspace › session` breadcrumb (e.g. `workspace 1 › agt`).
- **Testing**: regular (code-first); keep the existing suites green, add accessibility-identifier
  checks where they add value. Visual aspects are manually verified (consistent with how the app
  already treats native panels).

### Title-bar approach (validated with codex against the Xcode 26.5 SDK)

Use **one `NSTitlebarAccessoryViewController` with `layoutAttribute = .top`**, installed from the
existing `WindowAccessor`/`TitleProbeView` (which already survives late window attachment and the
state-restoration de-miniaturize re-assert). This is the only approach that makes the header part
of AppKit's real titlebar geometry — traffic lights remain AppKit-owned and correctly positioned,
and window content is laid out against AppKit's non-obscured content area instead of sliding under
the buttons (the failure mode of the earlier rejected `fullSizeContentView` + SwiftUI-VStack
attempt).

Required window setup (set `fullSizeContentView` BEFORE adding the accessory):

```swift
window.styleMask.insert(.fullSizeContentView)
window.titleVisibility = .hidden
window.titlebarAppearsTransparent = true
window.titlebarSeparatorStyle = .none
window.title = desiredTitle            // still set, for the window menu; just not drawn
// idempotent find-or-create by view identifier, then:
controller.layoutAttribute = .top
controller.view = <hosting container, ~30px tall>
```

Codex pitfalls folded into the tasks below:
- Only one `.top` accessory per window; all header content goes in that one view.
- Paint an opaque dark background in the header view; avoid `.bar`/toolbar material (Tahoe Liquid
  Glass).
- `titlebarSeparatorStyle = .none` at the window level overrides split-view item preferences.
- Do NOT also use `.windowStyle(.hiddenTitleBar)` or a SwiftUI toolbar title placement.
- Reserve a leading inset (~80px) for the traffic lights; do not reposition `standardWindowButton`
  manually (last resort only). Use `NSWindow.windowTitlebarLayoutDirection` rather than assuming
  left.
- Support window dragging via the header container's empty area (`mouseDownCanMoveWindow`), NOT
  `window.isMovableByWindowBackground = true` (which would make terminal background clicks drag
  the window).
- After install, verify the content view's top `safeAreaInsets` so rows/terminal don't overlap the
  header; if only sidebar *material* extends under the header that is normal.

## Context (from discovery)

- **Files involved**:
  - `agt/ContentView.swift` — `NavigationSplitView { WorkspaceSidebar … } detail: { VStack { detailPane; if !statusBarHidden { Divider(); statusBar } } }`, plus `.background(WindowAccessor(title:))`. Holds `WindowAccessor`/`TitleProbeView`.
  - `agt/Views/WorkspaceSidebar.swift` — `NSOutlineView` (`.style = .sourceList`) in an `NSScrollView` (`drawsBackground=false`); `SidebarCellView` (name `textField` + trailing `tokenField`); `SidebarRowView` (overrides `isEmphasized=true`); the `@MainActor Coordinator` builds cells in `outlineView(_:viewFor:)` and rows in `outlineView(_:rowViewForItem:)`.
  - `agt/Views/GitStatusPill.swift` — flat `HStack` of branch glyph + name + ahead/behind/dirty + worktree chip; `.font(.callout)`; accessibility id `git-pill`.
  - `agt/agtApp.swift` — `Window("agt", id:"main")`, `.commands { … Hide/Show Status Bar … }`; `AppDelegate`.
  - `agtCore` (host-free) — `AppStore`, `Session.displayName`, `Workspace.name`, `GitStatus`. **No agtCore change is needed**: the breadcrumb is derived in the app target from existing model data; no new persisted state.
- **Patterns to preserve**:
  - The sidebar's cell reuse + node-identity caching, rename/selection wiring, drag-and-drop, and the gitStatus per-row reconcile must keep working — restyle the *views*, not the data flow.
  - Accessibility identifiers `session-row`, `workspace-row`, `edit-field`, `add-session`, `git-pill`, `git-compact` back the XCUITests and MUST be preserved.
  - `WindowAccessor`/`TitleProbeView` is the single, proven NSWindow touch-point; extend it rather than adding a second window-reaching path.
- **Constraints**: app target owns SwiftUI/AppKit; `agtCore` must not import AppKit. Strict concurrency `complete` (all new AppKit/SwiftUI types are `@MainActor`). The terminal area is libghostty (its background is the ghostty theme; out of scope).

## Development Approach

- **Testing approach**: Regular (code-first). This is a visual redesign — most changes are not
  meaningfully unit-testable. Each task: keep `swift test` (agtCore) and the `agtUITests` suite
  green, and add an accessibility-identifier check where it adds real signal (e.g. the header
  breadcrumb static text). Visual fidelity is confirmed by building + launching and the user
  eyeballing each phase.
- Complete each phase fully (build + launch + user confirmation) before the next.
- Small, focused changes; preserve all existing data flow, accessibility ids, and tests.
- **Pre-commit gate** (per CLAUDE.md): `cd agtCore && swift test` + the full `agtUITests` suite must
  pass before any commit. During iteration, run only the relevant `-only-testing:` target.
- Update this plan's checkboxes as work completes; add ➕ for newly discovered tasks, ⚠️ for blockers.

## Testing Strategy

- **agtCore unit tests**: no model changes are planned, so none expected. If a task ends up adding
  derivation logic to `agtCore` (e.g. a breadcrumb formatter), it MUST be `Sendable`/pure and unit
  tested in `agtCoreTests` following the existing one-test-file-per-source convention.
- **agtUITests (XCUITest)**: the regression gate. Every phase must leave `SidebarUITests`,
  `GitStatusUITests`, and `StatusBarMenuUITests` green. Add focused checks:
  - Phase 1: the existing sidebar tests already exercise selection/rename/drag — they validate the
    restyle didn't break interaction.
  - Phase 3: add a check that the header breadcrumb static text (`titlebar-breadcrumb`) exists and
    reflects the active session.
- **Manual verification** (unavoidable for chrome): traffic-light placement, no content overlap,
  flat selection appearance, dark palette, relaunch/de-miniaturize, status-bar toggle, full-screen
  transition.

## Progress Tracking

- mark completed items `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document blockers with ⚠️ prefix
- keep this plan in sync with actual work

## Solution Overview

- **Shared palette** (`agt/Views/Theme.swift`, new): one `enum Theme` exposing the Zed-like colors
  as both `NSColor` (AppKit cells/rows/containers) and SwiftUI `Color` (status bar, header)
  accessors, so the three areas stay visually consistent. Fixed dark greys for panel/header/status
  backgrounds and text; selection = `NSColor.controlAccentColor` (adaptive).
- **Sidebar**: opaque dark background on the scroll/outline; `SidebarRowView.drawSelection(in:)`
  draws a flat full-width accent fill (replacing the source-list rounded pill); denser row height +
  smaller cell font; a leading `NSImageView` icon per cell (workspace folder vs session terminal);
  cell text color reacts to selection (white on accent, primary grey otherwise) and uses muted grey
  for the git token.
- **Status bar**: thinner dark Zed bar; left slot for context info, right slot for the restyled
  `GitStatusPill` (flatter, muted, smaller).
- **Title bar**: new `agt/Views/TitlebarHeader.swift` with the SwiftUI `AgtHeaderView` (breadcrumb),
  a draggable hosting container, and an idempotent `installAgtHeader(on:breadcrumb:)`; the existing
  `WindowAccessor`/`TitleProbeView` calls it on attach and on `breadcrumb` change. `ContentView`
  computes the `workspace › session` string and feeds it to `WindowAccessor`.

## Technical Details

- **Palette (proposed values; tune during Phase 1):**
  - panel/sidebar bg `#1E2025`, header bg `#1B1D22`, status bg `#1B1D22`, divider `#34373E`
  - primary text `#C8CCD4`, muted text `#7A828E`, selection text `white`
  - selection fill `NSColor.controlAccentColor`
  - These are fixed dark values (the chrome reads as dark regardless of system appearance — matching
    Zed); selection alone is appearance/accent-adaptive.
- **Flat selection**: prefer overriding `SidebarRowView.drawSelection(in dirtyRect:)` to fill the
  full row bounds with the accent (flat, no inset). If `.sourceList` still forces an inset/rounded
  pill, fall back to `outline.selectionHighlightStyle = .regular`. Keep `isEmphasized=true` (already
  present) so the fill stays accent-colored while focus is in the terminal.
- **Cell text color (decided mechanism)**: set `textField.textColor` and the icon tint in
  `outlineView(_:viewFor:)` based on whether that row is the currently-selected row (white when
  selected, `Theme` primary grey otherwise) AND re-apply on selection change by reloading the
  affected rows from the coordinator's `outlineViewSelectionDidChange`/`syncSelection` (both already
  exist and run on the main actor). Do NOT rely on `NSTableCellView.backgroundStyle` propagation —
  cells are reused independently of rows and `SidebarRowView` holds no reference to the cell's text
  field, so the explicit viewFor + reload-on-selection path is the reliable one. The git token uses
  `Theme.mutedText` (not the system `secondaryLabelColor`, which won't read consistently on the
  fixed `#1E2025` panel).
- **Icons**: `NSImageView` with SF Symbols — workspace `folder` (or `folder.fill`), session
  `terminal` (or `chevron.left.forwardslash.chevron.right`), tinted muted grey; selected row tints
  white. Add as a leading subview in `makeCell`, with the name field's leading anchored to the icon's
  trailing.
- **Header view** `AgtHeaderView(breadcrumb: String)`: `HStack` with ~80px leading inset (traffic
  lights), the breadcrumb (`workspace` muted, `›` muted, `session` primary), `Spacer()`, trailing
  reserved. Opaque `Theme.headerBackground`. Fixed height 30. Accessibility id `titlebar-breadcrumb`
  on the breadcrumb text.
- **Header host/install** (`TitlebarHeader.swift`):
  - `final class HeaderContainerView: NSView` wrapping an `NSHostingView`; `mouseDownCanMoveWindow`
    returns true over empty areas so the header drags the window; `identifier = "agt.titlebar.header"`.
  - `installAgtHeader(on window: NSWindow, breadcrumb: String)`: sets the window styleMask/title flags
    (in the order above), finds an existing accessory controller whose view identifier matches (else
    creates one, `layoutAttribute = .top`, appends via `addTitlebarAccessoryViewController`), and
    updates the hosting `rootView` with the new breadcrumb. Idempotent across repeated calls.
- **Breadcrumb derivation** (app target, in `ContentView`): active session → its owning workspace
  name + session `displayName`, joined ` › `; falls back to just the session name, or `agt` when no
  selection. Drives both the (hidden) `window.title` and the header.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, and doc updates in this repo.
- **Post-Completion** (no checkboxes): manual visual verification scenarios.

## Implementation Steps

### Task 1: Shared Zed palette

**Files:**
- Create: `agt/Views/Theme.swift`

- [ ] add `enum Theme` (app target) exposing fixed dark-grey panel/header/status/divider colors and
      primary/muted/selected text colors, each available as `NSColor` and SwiftUI `Color`
- [ ] expose `selectionFill` as `NSColor.controlAccentColor` (adaptive accent) with a matching
      `Color` accessor
- [ ] keep values in one place so all three areas reference the same palette
- [ ] build the app target (no behavior change yet); confirm it compiles — this is the only gate
      for Task 1 (`Theme` lives in the app target, so `swift test` on agtCore can't exercise it and
      agtCore is provably untouched)

### Task 2: Sidebar — dark background + flat full-width accent selection

**Files:**
- Modify: `agt/Views/WorkspaceSidebar.swift`

- [ ] paint the sidebar an opaque `Theme` dark grey: set the `NSScrollView`/`NSOutlineView`
      background (drawsBackground + backgroundColor) so the translucent source-list material no
      longer shows
- [ ] override `SidebarRowView.drawSelection(in:)` to fill the full row bounds with
      `Theme.selectionFill` (flat, full-width, no rounded inset); fall back to
      `selectionHighlightStyle = .regular` if `.sourceList` still insets
- [ ] drive cell text color via the decided mechanism (set `textField.textColor` in
      `outlineView(_:viewFor:)` for the selected row + reload affected rows on selection change):
      white when selected, `Theme` primary grey otherwise; switch the git token to `Theme.mutedText`
- [ ] verify rename (`edit-field`), selection (`session-row`), and drag still work (ids unchanged)
- [ ] add an assertion that selecting a session row leaves THAT row selected and still `isHittable`
      after the `drawSelection` rewrite (guards the selection-fill change from altering hit geometry)
- [ ] run `-only-testing:agtUITests/SidebarUITests` — must pass before Task 3

### Task 3: Sidebar — density, fonts, and leading icons

**Files:**
- Modify: `agt/Views/WorkspaceSidebar.swift`

- [ ] reduce row height / tighten vertical metrics for a denser Zed feel; reduce cell font sizes
      (workspace slightly emphasized, session regular, both smaller than current)
- [ ] add a leading `NSImageView` SF-symbol icon per cell in `makeCell` (workspace `folder`, session
      `terminal`), tinted muted grey, white when selected; re-anchor the name field after the icon
- [ ] reset icon state on cell reuse (alongside the existing `isEditable`/token reset) so a recycled
      cell shows the right symbol/tint
- [ ] confirm the git token still right-aligns and truncation order (name truncates first) is intact
- [ ] run `-only-testing:agtUITests/SidebarUITests` — must pass before Task 4

### Task 4: Status bar — Zed restyle

**Files:**
- Modify: `agt/ContentView.swift`
- Modify: `agt/Views/GitStatusPill.swift`

- [ ] restyle `ContentView.statusBar`: thinner height, opaque `Theme` dark background (drop `.bar`),
      a left slot for context info and the right slot keeping the git pill; replace the system
      `Divider()` seam above the bar with a `Theme.divider`-colored separator so it stays visible on
      the dark opaque bar
- [ ] restyle `GitStatusPill` to the Zed aesthetic: smaller font, flatter/muted colors, keep the
      branch/ahead/behind/dirty/worktree content and the `git-pill`/`git-compact` accessibility hooks
- [ ] keep the `Hide/Show Status Bar` toggle behavior (the `if !store.statusBarHidden` gate) intact
- [ ] run `-only-testing:agtUITests/GitStatusUITests` and `-only-testing:agtUITests/StatusBarMenuUITests`
      — must pass before Task 5

### Task 5: Title bar — header view + draggable host + idempotent install

**Files:**
- Create: `agt/Views/TitlebarHeader.swift`

- [ ] add `AgtHeaderView(breadcrumb: String)`: ~80px leading inset for traffic lights, breadcrumb
      (`workspace` muted, `›` muted, `session` primary), opaque `Theme.headerBackground`, fixed 30px
      height, accessibility id `titlebar-breadcrumb` on the text
- [ ] add `HeaderContainerView: NSView` hosting an `NSHostingView(rootView:)`, with
      `mouseDownCanMoveWindow` true over empty areas and `identifier = "agt.titlebar.header"`
- [ ] add `installAgtHeader(on:breadcrumb:)`: set `fullSizeContentView` + `titleVisibility=.hidden` +
      `titlebarAppearsTransparent=true` + `titlebarSeparatorStyle=.none` (in that order), then
      find-or-create the `.top` `NSTitlebarAccessoryViewController` by view identifier and update its
      hosting `rootView` with the breadcrumb (idempotent; never blind-adds on repeat)
- [ ] build the app target; confirm it compiles (not yet wired into the window)
- [ ] run `cd agtCore && swift test` (sanity) — must pass before Task 6

### Task 6: Wire the header into the window via WindowAccessor

**Files:**
- Modify: `agt/ContentView.swift`

- [ ] compute the `workspace › session` breadcrumb in `ContentView` from the active session + its
      workspace (fallback to session name, then `agt`)
- [ ] extend `WindowAccessor`/`TitleProbeView` to take the breadcrumb and call
      `installAgtHeader(on:breadcrumb:)` in `viewDidMoveToWindow` and whenever the breadcrumb changes
      (`updateNSView`), keeping the existing title set + de-miniaturize/bring-forward re-assert
- [ ] verify after install: traffic lights sit inside the header and are clickable; sidebar/terminal
      do not overlap the header (inspect content `safeAreaInsets`); the status-bar toggle still works;
      relaunch + de-miniaturize still bring the window forward correctly
- [ ] assert the FIRST sidebar row is fully `isHittable` under the new header (not just "no overlap")
      — if the top row lands under the 30px header it becomes unclickable and silently breaks the
      `rightClick()`-based `SidebarUITests`; if so, add a top inset to the sidebar content
- [ ] add a UI check that `titlebar-breadcrumb` exists and reflects the active session (extend an
      existing XCUITest or add a small one)
- [ ] run the full `agtUITests` suite — must pass before Task 7

### Task 7: Verify acceptance criteria

- [ ] sidebar: dark panel, dense rows, leading icons, flat full-width accent selection with readable
      text — matches the Zed reference
- [ ] status bar: thin dark bar, left info + right git indicators
- [ ] title bar: custom dark header with `workspace › session`, traffic lights overlaid and working,
      no content overlap, drag works, no Liquid Glass capsule, no separator line
- [ ] full-screen toggle, window resize, and relaunch all keep the header + traffic lights correct
- [ ] run full gate: `cd agtCore && swift test` + full `agtUITests` suite

### Task 8: [Final] Documentation

- [ ] update `CLAUDE.md`: add a short note on the Zed chrome — the shared `Theme` palette, the
      `.top` `NSTitlebarAccessoryViewController` header installed via `WindowAccessor` (and why, with
      the `fullSizeContentView`-first ordering + don't-move-traffic-lights gotchas), and the flat
      sidebar selection
- [ ] update `ARCHITECTURE.md`/`README.md` if they describe the chrome/sidebar/status bar
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Manual verification — no checkboxes, informational only.*

**Manual visual/UX checks:**
- Compare side-by-side with the Zed reference screenshot for sidebar density, icon style, selection,
  and header layout; tune palette values and the traffic-light inset to taste.
- Traffic-light hover/click, window drag via the header, and the menu/window-title behavior with the
  native title hidden.
- Full-screen enter/exit and multi-display moves: confirm the header height and traffic-light
  centering hold (Tahoe can relayout titlebar buttons across these transitions).
- Dark appearance is the design target; if the app is ever used in Light mode, confirm the fixed dark
  chrome still reads acceptably (or decide to gate it later).

---

Smells pre-check: skipped — non-Go project.

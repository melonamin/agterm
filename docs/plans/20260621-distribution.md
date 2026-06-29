# Signed + Notarized DMG Distribution (GitHub Releases + Homebrew cask)

## Update (2026-06-29): interim UNSIGNED, CI-by-tag distribution

The signed + notarized end state below is still the target, but it is blocked on Apple (org-account conversion under review). To ship in the meantime, releases now go out as **ad-hoc-signed, NOT notarized** builds, published by **CI on a `v*` tag**, with a documented Gatekeeper workaround. This reverts cleanly once notarization is available (drop `AGTERM_ALLOW_UNSIGNED`, add signing creds/identity).

What changed from the original local-signed plan:
- **`scripts/release.sh`** stays the single source of truth and the CI entry point. `--publish` now refuses an ad-hoc build *unless* `AGTERM_ALLOW_UNSIGNED=1` (CI sets it). The sign/notarize blocks already no-op when no Developer ID identity is present, so the unsigned path needs nothing else. The GitHub release body is built by a new `release_notes()` helper: the matching `CHANGELOG.md` section + a fixed unsigned-install footer (`xattr -cr …`), via `--notes-file` (replacing `--generate-notes`).
- **`.github/workflows/release.yml`** (new) — `on: push: tags: ['v*']`, `runs-on: macos-26`, caches libghostty like `ci.yml`, sets a bot git identity + `gh auth setup-git`, then runs `scripts/release.sh "${GITHUB_REF_NAME#v}" --publish`.
- **`packaging/agterm.rb`** — added a `postflight` that strips `com.apple.quarantine` so `brew install --cask` opens the unsigned app with no prompt (mirrors `thdxg/macterm`'s production cask). Remove once notarized.
- **`README.md`** Install section — rewritten from "signed + notarized, no workaround" to the interim reality: cask auto-strips quarantine; direct-DMG users run `xattr -cr /Applications/agterm.app`. Right-click → Open is explicitly NOT offered — Apple removed it as a Gatekeeper bypass in macOS 15 Sequoia (verified on 26.5.1); the GUI fallback is System Settings → Privacy & Security → Open Anyway.
- **`CHANGELOG.md`** (new, repo root) — Keep-a-Changelog in the sibling style (revdiff: New Features / Improvements / Bug Fixes), hand-maintained; the release body is sourced from it. First entry: v0.3.1.

Manual prerequisites for CI publish:
- Secret **`HOMEBREW_TAP_PAT`** on `umputun/agterm`: a fine-grained PAT with **Contents: read/write on BOTH `umputun/agterm` (release) and `umputun/homebrew-apps` (cask push)** — the default `GITHUB_TOKEN` cannot push to the separate tap repo. Create it once; one job both creates the agterm release and pushes the cask.
- First tag: **v0.3.1** (`git tag v0.3.1 && git push origin v0.3.1`).

The Apple-gated tasks below (signing identity, notarization) remain the eventual target and are unaffected by the interim path.

## Overview
- Ship `agterm` as a Developer ID **signed + Apple-notarized + stapled** `.dmg` so macOS Gatekeeper runs it without the "unidentified developer / cannot be opened" block.
- Two channels: a GitHub Release artifact (direct download) and a Homebrew **cask** in the existing `umputun/homebrew-apps` tap (`brew install --cask umputun/apps/agterm`).
- Release is run **locally on the maintainer's Mac** via `scripts/release.sh` (no GitHub Actions). The Developer ID cert lives in the login keychain; notary creds are stored once via `xcrun notarytool store-credentials` and referenced by profile name.
- No Sparkle / in-app auto-update (out of scope). Updates come from `brew upgrade` or a new release download.
- arm64-only (Apple Silicon): `GhosttyKit.xcframework` ships only a `macos-arm64` slice (`libghostty-internal-fat.a`, statically linked), so the bundle is self-contained but not universal. Universal would require rebuilding ghostty for x86_64 — explicitly out of scope.

## Context (from discovery)
- `project.yml`: ad-hoc signing (`CODE_SIGN_IDENTITY "-"`, `DEVELOPMENT_TEAM ""`), `ENABLE_HARDENED_RUNTIME YES`, `ARCHS arm64`, `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` hardcoded `0.0.0`. Entitlements at `agterm/agterm.entitlements`.
- Existing `Bundle agtermctl CLI` postBuildScript in `project.yml` already builds `agtermctl` release, copies it to `Contents/MacOS/agtermctl`, signs it, and re-signs the whole app `codesign --force --deep --options runtime --sign -`. **This is the signing integration point.**
- `scripts/build.sh` (Release build), `scripts/setup.sh` (builds GhosttyKit from pinned upstream ghostty). App is statically linked and self-contained (app + static ghostty + `Resources/ghostty` + `Resources/terminfo` + bundled `agtermctl`). No git tags yet, no `.github/workflows`.
- Tap `umputun/homebrew-apps` (tap name `umputun/apps`) exists; `Casks/` holds only `.gitkeep` (existing entries are GoReleaser **Formulae** for CLI tools). `agterm` is its **first cask**.

## Reference recipes (verified by reading the repos)
- **macterm** (`thdxg/macterm`): release/DMG/cask plumbing structure — but ships **ad-hoc, NOT notarized** (its `AGENTS.md` tells users to `xattr -cr`). Borrow plumbing only.
- **cmux** (`manaflow-ai/cmux`, `.github/workflows/nightly.yml`): the real sign+notarize recipe. Locally we drop the keychain-import step (cert already local) and use `--keychain-profile` instead of `--apple-id/--password`. Core sequence: `ditto -c -k --sequesterRsrc --keepParent app app.zip` → `xcrun notarytool submit app.zip --wait` (check status `Accepted`, dump `notarytool log` on failure) → `xcrun stapler staple app` → `stapler validate` → `spctl -a -vv --type execute` → build DMG → notarize + staple the DMG too.

## Development Approach
- **Testing approach**: Regular / validation-based. This is packaging plumbing (project.yml, shell script, a cask `.rb`, README) — there is no host-free unit-testable logic added. The gates are: `cd agtermCore && swift test` stays green, and a normal **ad-hoc Debug build still works unchanged** (the `AGTERM_SIGN_IDENTITY` default `-` path).
- Make small, focused changes; keep scope minimal (personal-project local release flow, not CI).
- **Do NOT run the full UI suite as a gate** (per the CLAUDE.md test-cadence convention) — distribution changes don't touch app behavior. Run focused checks only.
- Maintain backward compatibility: day-to-day `scripts/run.sh` / `scripts/build.sh` must behave exactly as before.

## Testing Strategy
- **swift test**: `cd agtermCore && swift test` must stay green (no core changes expected, but verify).
- **ad-hoc build regression**: after the `project.yml` change, a plain `scripts/run.sh` / Debug build must still produce a launchable ad-hoc app (no Developer ID required).
- **release.sh dry-run (pre-Apple)**: the build + DMG-packaging portion must run end-to-end producing an unsigned/ad-hoc DMG locally, so everything except the Apple-gated notarization is exercised before membership is active.
- **Notarized validation (Apple-gated)**: once the cert + creds exist, run the full `release.sh`, confirm `spctl -a -vv --type execute` passes and `stapler validate` succeeds, and verify a fresh download opens on a clean/second Mac without a Gatekeeper prompt.

## Prerequisites (Apple — manual, external, BLOCKS final validation)
**Status (2026-06-21):** membership active; an Individual `Developer ID Application` cert is installed and signing is validated. To keep the maintainer's legal name off the artifacts, conversion to an **Organization** account (Brave Elk LLC, D-U-N-S 130180527) has been requested and is under Apple review (~weeks). The first real notarized release waits on: org approval → reissue the Developer ID cert under the LLC → `notarytool store-credentials agterm-notary`.

These cannot be done in the codebase and block the notarization tasks until complete:
1. Enroll in the Apple Developer Program (individual, $99/yr) and wait for activation.
2. Create a **Developer ID Application** certificate; confirm it + its private key are in the login keychain. Note the identity string `Developer ID Application: <name> (TEAMID)` and the Team ID.
3. Create an app-specific password at appleid.apple.com, then store notary creds: `xcrun notarytool store-credentials agterm-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>` (profile name `agterm-notary`).

Until these are done, implement Tasks 1–4 (the `-` ad-hoc path stays the default and keeps working) and run the dry-run; Task 5 is the gated final validation.

## What Goes Where
- **Implementation Steps** (`[ ]`): `project.yml` signing parameterization, `scripts/release.sh`, the cask file content, README — all in this repo (the cask content is authored here even though it's published to the tap repo).
- **Post-Completion** (no checkboxes): Apple enrollment/cert/creds (above), publishing the cask to `umputun/homebrew-apps`, and the clean-Mac install verification.

## Implementation Steps

### Task 1: Parameterize signing identity + secure timestamp in the bundle build phase

**Files:**
- Modify: `project.yml` (the `Bundle agtermctl CLI` postBuildScript)

- [x] ⚠️ DEVIATION: Developer ID signing was moved OUT of the build phase into `release.sh`. Implementing the `AGTERM_SIGN_IDENTITY` build-phase param revealed Xcode's own final code-sign runs AFTER the phase, re-signs the app ad-hoc, and drops the secure timestamp (verified: app came out `adhoc`/no timestamp while the helper kept Developer ID). So the build phase stays **ad-hoc** (`--sign -`) and `release.sh` does the authoritative Developer ID + `--timestamp` re-sign after `xcodebuild` returns (Task 2). `project.yml` is unchanged except a clarifying comment.
- [x] normal Debug build verified unchanged: builds ad-hoc, `codesign --verify --deep --strict` passes, `agtermctl` runs.
- [x] `cd agtermCore && swift test` green (301 tests).

### Task 2: scripts/release.sh — local build → (gated) notarize → DMG → publish

**Files:**
- Create: `scripts/release.sh`

- [x] Accept a version (`$1`), validate `^[0-9]+\.[0-9]+\.[0-9]+$`; derive `TAG="v$VERSION"`; `--publish` is opt-in (build/notarize without it, publish only when passed).
- [x] Build: `scripts/setup.sh` → `xcodegen generate` → plain `xcodebuild … -configuration Release build` (NOT archive); the `.app` at `build/DerivedData/Build/Products/Release/agterm.app` is copied into a staging dir.
- [x] Authoritative signing AFTER `xcodebuild`: auto-detect the `Developer ID Application` identity (`security find-identity`, or `AGTERM_SIGN_IDENTITY` override), then `codesign --force --options runtime --timestamp` the nested `agtermctl` and the app bundle. **Validated** end-to-end against the real cert: app + helper both Developer ID + secure timestamp + hardened runtime, `--verify --deep --strict` OK. No identity → ad-hoc dry-run.
- [ ] Notarize the app: `ditto -c -k --sequesterRsrc --keepParent` → `notarytool submit --keychain-profile agterm-notary --wait` (jq status check, `notarytool log` on failure) → `stapler staple`/`validate` → `spctl --type execute`. WRITTEN; ⚠️ not validated (gated on notary creds + org cert).
- [x] Package DMG via `hdiutil create … UDZO` with an `/Applications` symlink (no `create-dmg` node dep).
- [ ] Notarize + staple the DMG, then `spctl -a -vv -t open --context context:primary-signature`. WRITTEN; ⚠️ gated on creds.
- [x] Publish (behind `--publish`): `gh release create`/`upload --clobber` the DMG. WRITTEN; not run.
- [x] Bump cask (behind `--publish`): `shasum -a 256`, clone `umputun/homebrew-apps`, seed from `packaging/agterm.rb` if the cask is absent (first publish), `sed` version/sha256, commit + push (no-op-diff guarded). WRITTEN; not run.
- [x] `set -euo pipefail`, per-stage status messages, notarize/publish stages conditional.
- [ ] ⚠️ Full `scripts/release.sh` dry-run not yet executed end-to-end (signing steps validated manually; gated on running the whole script).

### Task 3: Homebrew cask content

**Files:**
- Create: `packaging/agterm.rb` (source-of-truth copy in this repo; published to `umputun/homebrew-apps:Casks/agterm.rb`)

- [x] Write the cask: `version`, `sha256`, `url "https://github.com/umputun/agterm/releases/download/v#{version}/agterm-#{version}.dmg"`, `name "agterm"`, `desc`, `homepage`.
- [x] Constraints: `depends_on macos: ">= :sonoma"` (macOS 14 floor) and `depends_on arch: :arm64`.
- [x] `app "agterm.app"` + `binary "#{appdir}/agterm.app/Contents/MacOS/agtermctl", target: "agtermctl"`. (README/Task 4 must tell cask users NOT to also run the in-app installer — competing symlink.)
- [x] `zap trash:` the app's state/support dirs (`~/Library/Application Support/agterm`, prefs plist, saved app state) for clean uninstall.
- [x] File-header note that `scripts/release.sh` rewrites `version`/`sha256` on each release.

### Task 4: README distribution/install section

**Files:**
- Modify: `README.md`

⚠️ Deferred until the first release exists (otherwise the cask command + DMG URL point at a 404).

- [ ] Add an Install/Distribution section: `brew install --cask umputun/apps/agterm` and the direct DMG download from Releases.
- [ ] State it's **arm64-only (Apple Silicon)** and signed + notarized (no `xattr` workaround needed).
- [ ] Cross-reference the `agtermctl` CLI: the cask `binary` stanza installs it automatically (cask users should NOT run the in-app installer); the in-app Help ▸ Install Command Line Tool is for **direct DMG** users only.

### Task 5 (Apple-gated): Full notarized release validation
- [ ] ⚠️ BLOCKED until Apple membership active + Developer ID cert in keychain + `notarytool store-credentials agterm-notary` done (see Prerequisites).
- [ ] Run `scripts/release.sh` for a real version with signing; confirm app + DMG both notarized `Accepted` and `stapler validate` passes for both. Verify the app with `spctl -a -vv --type execute <app>` AND the DMG with `spctl -a -vv -t open --context context:primary-signature <dmg>` — both must report `accepted` / `source=Notarized Developer ID`.
- [ ] Download the published DMG on a clean/second Mac (or a fresh user); confirm it opens with no Gatekeeper block.

### Task 6: [Final] Docs + cleanup
- [ ] Update CLAUDE.md if the release flow introduces conventions worth recording (the `AGTERM_SIGN_IDENTITY` hook, the local-release model, arm64-only).
- [ ] Publish `packaging/agterm.rb` to `umputun/homebrew-apps:Casks/agterm.rb` (first cask in the tap).
- [ ] Move this plan to `docs/plans/completed/`.

## Post-Completion
*Manual / external — no checkboxes*
- Apple Developer Program enrollment + Developer ID cert + `notarytool store-credentials` (Prerequisites).
- First-time tap setup: commit `Casks/agterm.rb` to `umputun/homebrew-apps`; verify `brew install --cask umputun/apps/agterm` end-to-end.
- Clean-Mac Gatekeeper verification of a downloaded DMG.
- Optional future scope (not now): universal (x86_64) build, CI-based release, Sparkle auto-update.

---
paths:
  - "scripts/release.sh"
---

## Release (`scripts/release.sh`)

- **Releases are cut LOCALLY, not by CI — there is NO `release.yml`.**
  `scripts/release.sh <version> --publish` runs on the maintainer's Mac, the only place the
  `Developer ID Application: Brave Elk LLC` cert and the `agterm-notary` keychain profile live.
  It builds Release, then signs + notarizes + staples the app AND the DMG (the DMG container is
  codesigned before notarizing — `hdiutil`'s image is otherwise unsigned and fails the `spctl`
  primary-signature check), creates the tag + GitHub release, uploads the DMG, and pushes the Homebrew
  cask to `umputun/homebrew-apps` with the maintainer's own `gh` auth (no `HOMEBREW_TAP_PAT` needed).
  A no-`--publish` run is a full dry-run (build → sign → notarize → staple → `spctl`) that stops before
  uploading.
- **At release time, run the new `CHANGELOG.md` version section through the `draft-approval` skill BEFORE
  writing/committing it** — write the section to a temp file, open it in `draft-review.sh` (revdiff),
  address annotations, then get an explicit in-chat go-ahead.
  Do NOT just paste the section inline and ask — `scripts/release.sh` publishes that exact section as the
  GitHub release body (release.sh:70-85), so it is outward-facing text and gets the full
  draft-approval/revdiff flow, same as a `gh`/`glab` comment.
- **Commit AND PUSH the changelog + website bump to `master` BEFORE `release.sh --publish`.**
  `release.sh` runs `gh release create "$TAG"` with NO `--target` (release.sh:166), so `gh` creates the
  tag at whatever `origin/master` HEAD currently points at — NOT the local HEAD.
  So the `docs: update changelog for vX.Y.Z` commit (and any other pre-release change) must be pushed to
  `origin/master` first, or the tag lands on the previous commit and the release ships without the
  changelog.
  `release.sh` does NOT push the main repo itself (it only commits + pushes the Homebrew cask in a cloned
  tap dir); the maintainer pushes `master`.
- **The website `softwareVersion` bump is a SEPARATE manual pre-release step `release.sh` does NOT do.**
  Per the Website section in the root `CLAUDE.md`, bump `site/index.html`'s `SoftwareApplication`
  `softwareVersion` to the new version and push it to `master` as part of the release (Cloudflare Pages
  auto-deploys `site/` on push).
  It is easy to miss because nothing in `release.sh` touches it — fold it into the same pre-`--publish`
  push as the changelog.
  The `.dmg` links on the site point at the GitHub "latest" release, so only `softwareVersion` needs the
  bump.
